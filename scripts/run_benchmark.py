#!/usr/bin/env python3
"""Run the query catalog benchmark against the local PostgreSQL database."""

from __future__ import annotations

import argparse
import os
import random
import statistics
import subprocess
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb


EXPECTED_MOLECULES = 1975
WARMUP_RUNS = 3
PILOT_RUNS = 1
VARIANTS = {"seq": ("off", "off"), "gist": ("on", "on")}
DEFAULT_DSN = "postgresql://chem:chem_dev_pw@localhost:5432/chemdb"
SUMMARY_SQL = """
    SELECT query_id, variant,
           count(*) FILTER (WHERE status = 'success') AS iterations,
           count(*) FILTER (WHERE status = 'timeout') AS timeouts,
           min(exec_ms) FILTER (WHERE status = 'success') AS min_ms,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)
             FILTER (WHERE status = 'success') AS p50,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY exec_ms)
             FILTER (WHERE status = 'success')
             - percentile_cont(0.25) WITHIN GROUP (ORDER BY exec_ms)
             FILTER (WHERE status = 'success') AS iqr_ms,
           max(actual_rows) AS matches,
           mode() WITHIN GROUP (ORDER BY scan_type) AS scan_type,
           string_agg(DISTINCT index_name, ', ') FILTER (WHERE index_name IS NOT NULL) AS index_name,
           max(shared_read) AS max_shared_read,
           max(candidates) AS max_candidates,
           max(rows_removed_by_recheck) AS max_rows_removed_by_recheck,
           max(lossy_heap_blocks) AS max_lossy_heap_blocks
    FROM bench.run_results
    WHERE run_id = %s
    GROUP BY query_id, variant
    ORDER BY query_id, variant
"""
RATIO_SQL = """
    WITH paired AS (
        SELECT query_id, iteration,
               max(exec_ms) FILTER (
                   WHERE variant = 'seq' AND status = 'success'
               ) AS seq_ms,
               max(exec_ms) FILTER (
                   WHERE variant = 'gist' AND status = 'success'
               ) AS gist_ms
        FROM bench.run_results
        WHERE run_id = %s
          AND variant IN ('seq', 'gist')
        GROUP BY query_id, iteration
        HAVING count(*) FILTER (
                   WHERE variant = 'seq' AND status = 'success'
               ) = 1
           AND count(*) FILTER (
                   WHERE variant = 'gist' AND status = 'success'
               ) = 1
    )
    SELECT query_id,
           count(*) AS paired_iterations,
           percentile_cont(0.5) WITHIN GROUP (
               ORDER BY seq_ms / NULLIF(gist_ms, 0)
           ) AS median_seq_over_gist_ratio
    FROM paired
    GROUP BY query_id
    ORDER BY query_id
"""


def git_revision() -> str:
    root = Path(__file__).resolve().parents[1]
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    changes = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return f"{revision}-dirty" if changes.strip() else revision


def explain(cursor: psycopg.Cursor[Any], smarts: str) -> dict[str, Any]:
    cursor.execute(
        """
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT mol_id FROM molecules WHERE mol @> %s::qmol
        """,
        (smarts,),
    )
    result = cursor.fetchone()[0]
    return result[0]


def plan_metrics(
    plan: dict[str, Any],
) -> tuple[str | None, str | None, int | None, int | None, int | None]:
    scan_types = {
        "Bitmap Heap Scan",
        "Foreign Scan",
        "Index Only Scan",
        "Index Scan",
        "Parallel Seq Scan",
        "Seq Scan",
        "Tid Scan",
    }
    scan_type = None
    index_names: set[str] = set()
    candidates = 0
    has_bitmap_index_scan = False
    rows_removed_by_recheck = 0
    lossy_heap_blocks = 0
    has_bitmap_heap_scan = False
    nodes = [plan]
    while nodes:
        node = nodes.pop(0)
        if scan_type is None and node.get("Node Type") in scan_types:
            scan_type = node["Node Type"]
        if node.get("Index Name"):
            index_names.add(node["Index Name"])
        if node.get("Node Type") == "Bitmap Index Scan":
            has_bitmap_index_scan = True
            candidates += round(
                node.get("Actual Rows", 0) * node.get("Actual Loops", 1)
            )
        if node.get("Node Type") == "Bitmap Heap Scan":
            has_bitmap_heap_scan = True
            loops = node.get("Actual Loops", 1)
            rows_removed_by_recheck += round(
                node.get("Rows Removed by Index Recheck", 0) * loops
            )
            lossy_heap_blocks += node.get("Lossy Heap Blocks", 0)
        nodes.extend(node.get("Plans", []))
    return (
        scan_type,
        ", ".join(sorted(index_names)) or None,
        candidates if has_bitmap_index_scan else None,
        rows_removed_by_recheck if has_bitmap_heap_scan else None,
        lossy_heap_blocks if has_bitmap_heap_scan else None,
    )


def set_variant(cursor: psycopg.Cursor[Any], variant: str) -> None:
    indexscan, bitmapscan = VARIANTS[variant]
    cursor.execute(
        """
        SELECT set_config('enable_indexscan', %s, false),
               set_config('enable_bitmapscan', %s, false)
        """,
        (indexscan, bitmapscan),
    )


def explain_with_timeout(
    cursor: psycopg.Cursor[Any], smarts: str, timeout_ms: int
) -> dict[str, Any]:
    cursor.execute("BEGIN")
    cursor.execute(
        "SELECT set_config('statement_timeout', %s, true)",
        (f"{timeout_ms}ms",),
    )
    try:
        document = explain(cursor, smarts)
    except psycopg.errors.QueryCanceled:
        cursor.execute("ROLLBACK")
        raise
    cursor.execute("COMMIT")
    return document


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--label",
        default="benchmark",
        help="descriptive label recorded for this benchmark run (default: benchmark)",
    )
    parser.add_argument(
        "--variants",
        action="store_true",
        help="interleave sequential-scan and planner-free GiST variants per iteration",
    )
    parser.add_argument(
        "--dsn",
        default=os.environ.get("DATABASE_URL", DEFAULT_DSN),
        help="PostgreSQL connection string (default: DATABASE_URL or local Compose)",
    )
    parser.add_argument(
        "--statement-timeout-ms",
        type=int,
        default=30000,
        help="per-query PostgreSQL statement timeout in milliseconds (default: 30000)",
    )
    parser.add_argument(
        "--target-query-seconds",
        type=float,
        default=30,
        help="approximate timed-run budget per query for adaptive iterations (default: 30)",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=100,
        help="maximum timed iterations per query (default: 100)",
    )
    args = parser.parse_args()
    if args.statement_timeout_ms <= 0 or args.target_query_seconds <= 0 or args.max_iterations <= 0:
        parser.error("timeout, target duration, and max iterations must all be positive")

    with psycopg.connect(args.dsn, autocommit=True) as connection:
        with connection.cursor() as cursor:
            row_count = cursor.execute(
                """
                SELECT count(DISTINCT m.mol_id)
                FROM molecules AS m
                JOIN dataset_records AS r USING (mol_id)
                WHERE r.dataset = 'bbbp'
                """
            ).fetchone()[0]
            if row_count != EXPECTED_MOLECULES:
                raise RuntimeError(
                    f"Expected {EXPECTED_MOLECULES} distinct BBBP molecules, "
                    f"found {row_count}; refusing to run benchmark."
                )

            cursor.execute(
                """
                SELECT current_setting('server_version'),
                       current_setting('work_mem'),
                       current_setting('shared_buffers'),
                       current_setting('enable_seqscan'),
                       current_setting('enable_indexscan'),
                       current_setting('enable_bitmapscan')
                """
            )
            (
                pg_version,
                work_mem,
                shared_buffers,
                enable_seqscan,
                enable_indexscan,
                enable_bitmapscan,
            ) = cursor.fetchone()
            statement_timeout = f"{args.statement_timeout_ms}ms"
            settings = {
                "work_mem": work_mem,
                "shared_buffers": shared_buffers,
                "enable_seqscan": enable_seqscan,
                "enable_indexscan": enable_indexscan,
                "enable_bitmapscan": enable_bitmapscan,
                "statement_timeout": statement_timeout,
                "target_query_seconds": args.target_query_seconds,
                "max_iterations": args.max_iterations,
                "variants": list(VARIANTS) if args.variants else ["gist"],
                "paired_variants": args.variants,
            }

            queries = cursor.execute(
                """
                SELECT query_id, smarts
                FROM bench.query_catalog
                ORDER BY query_id
                """
            ).fetchall()
            if not queries:
                raise RuntimeError(
                    "bench.query_catalog is empty; seed the benchmark queries first."
                )

            run_id = cursor.execute(
                """
                INSERT INTO bench.runs
                    (label, git_sha, pg_version, row_count, settings)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING run_id
                """,
                (args.label, git_revision(), pg_version, row_count, Jsonb(settings)),
            ).fetchone()[0]

            variants = list(VARIANTS) if args.variants else ["gist"]
            for query_id, smarts in queries:
                for _ in range(WARMUP_RUNS):
                    for variant in random.sample(variants, k=len(variants)):
                        set_variant(cursor, variant)
                        try:
                            explain_with_timeout(
                                cursor, smarts, args.statement_timeout_ms
                            )
                        except psycopg.errors.QueryCanceled:
                            print(f"{query_id}/{variant}: warm-up timed out")

                durations = {variant: [] for variant in variants}
                iteration = 1
                target_ms = args.target_query_seconds * 1000
                max_iterations = args.max_iterations
                while iteration <= max_iterations:
                    for variant in random.sample(variants, k=len(variants)):
                        set_variant(cursor, variant)
                        try:
                            document = explain_with_timeout(
                                cursor, smarts, args.statement_timeout_ms
                            )
                        except psycopg.errors.QueryCanceled as error:
                            cursor.execute(
                                """
                                INSERT INTO bench.run_results
                                    (run_id, query_id, iteration, variant,
                                     status, timeout_ms, error_message)
                                VALUES (%s, %s, %s, %s, 'timeout', %s, %s)
                                """,
                                (
                                    run_id,
                                    query_id,
                                    iteration,
                                    variant,
                                    args.statement_timeout_ms,
                                    str(error),
                                ),
                            )
                            print(
                                f"{query_id}/{variant}: timed out after "
                                f"{args.statement_timeout_ms} ms"
                            )
                            continue
                        plan = document["Plan"]
                        shared_hit = plan.get("Shared Hit Blocks", 0)
                        shared_read = plan.get("Shared Read Blocks", 0)
                        (
                            scan_type,
                            index_name,
                            candidates,
                            rows_removed_by_recheck,
                            lossy_heap_blocks,
                        ) = plan_metrics(plan)
                        cursor.execute(
                            """
                            INSERT INTO bench.run_results
                                (run_id, query_id, iteration, variant, exec_ms,
                                 plan_rows, actual_rows, shared_hit, shared_read,
                                 scan_type, index_name, planning_ms, plan_json,
                                 candidates, rows_removed_by_recheck,
                                 lossy_heap_blocks)
                            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                    %s, %s, %s, %s, %s, %s)
                            """,
                            (
                                run_id,
                                query_id,
                                iteration,
                                variant,
                                document["Execution Time"],
                                plan["Plan Rows"],
                                plan["Actual Rows"],
                                shared_hit,
                                shared_read,
                                scan_type,
                                index_name,
                                document["Planning Time"],
                                Jsonb(document) if iteration == 1 else None,
                                candidates,
                                rows_removed_by_recheck,
                                lossy_heap_blocks,
                            ),
                        )
                        durations[variant].append(document["Execution Time"])

                    if iteration == PILOT_RUNS:
                        median_ms = max(sum(
                            statistics.median(samples)
                            if samples
                            else args.statement_timeout_ms
                            for samples in durations.values()
                        ), 1)
                        target_iterations = int(target_ms / median_ms)
                        max_iterations = max(
                            PILOT_RUNS,
                            min(args.max_iterations, target_iterations),
                        )
                        print(
                            f"{query_id}: {max_iterations} timed iteration(s) "
                            f"per variant (pilot pair median {median_ms:.3f} ms)"
                        )
                    iteration += 1

            summary = cursor.execute(SUMMARY_SQL, (run_id,)).fetchall()
            paired = (
                cursor.execute(RATIO_SQL, (run_id,)).fetchall()
                if args.variants
                else []
            )

    print(f"run_id={run_id}")
    print(
        "query_id\tvariant\titerations\ttimeouts\tmin_ms\tp50_ms\tiqr_ms"
        "\tmatches\tscan_type\tindex_name\tmax_shared_read\tmax_candidates"
        "\tmax_rows_removed_by_recheck\tmax_lossy_heap_blocks"
    )
    for (
        query_id,
        variant,
        iterations,
        timeouts,
        min_ms,
        p50,
        iqr,
        matches,
        scan_type,
        index_name,
        max_shared_read,
        max_candidates,
        max_rows_removed_by_recheck,
        max_lossy_heap_blocks,
    ) in summary:
        print(
            f"{query_id}\t{variant}\t{iterations}\t{timeouts}\t{min_ms}\t{p50}"
            f"\t{iqr}\t{matches}\t{scan_type}\t{index_name or '-'}"
            f"\t{max_shared_read}\t{max_candidates}"
            f"\t{max_rows_removed_by_recheck}\t{max_lossy_heap_blocks}"
        )
    if args.variants:
        print("query_id\tpaired_iterations\tmedian_seq_over_gist_ratio")
        for query_id, paired_iterations, ratio in paired:
            print(f"{query_id}\t{paired_iterations}\t{ratio}")


if __name__ == "__main__":
    main()
