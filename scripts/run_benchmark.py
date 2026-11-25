#!/usr/bin/env python3
"""Run the query catalog benchmark against the local PostgreSQL database."""

from __future__ import annotations

import argparse
import os
import statistics
import subprocess
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb


EXPECTED_MOLECULES = 1975
WARMUP_RUNS = 3
PILOT_RUNS = 1
DEFAULT_DSN = "postgresql://chem:chem_dev_pw@localhost:5432/chemdb"
SUMMARY_SQL = """
    SELECT query_id,
           count(*) AS iterations,
           min(exec_ms) AS min_ms,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS p50,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY exec_ms)
             - percentile_cont(0.25) WITHIN GROUP (ORDER BY exec_ms) AS iqr_ms,
           max(actual_rows) AS matches,
           mode() WITHIN GROUP (ORDER BY scan_type) AS scan_type,
           string_agg(DISTINCT index_name, ', ') FILTER (WHERE index_name IS NOT NULL) AS index_name,
           max(shared_read) AS max_shared_read
    FROM bench.run_results
    WHERE run_id = %s
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


def buffer_totals(plan: dict[str, Any]) -> tuple[int, int]:
    hits = plan.get("Shared Hit Blocks", 0)
    reads = plan.get("Shared Read Blocks", 0)
    for child in plan.get("Plans", []):
        child_hits, child_reads = buffer_totals(child)
        hits += child_hits
        reads += child_reads
    return hits, reads


def plan_access(plan: dict[str, Any]) -> tuple[str | None, str | None]:
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
    nodes = [plan]
    while nodes:
        node = nodes.pop(0)
        if scan_type is None and node.get("Node Type") in scan_types:
            scan_type = node["Node Type"]
        if node.get("Index Name"):
            index_names.add(node["Index Name"])
        nodes.extend(node.get("Plans", []))
    return scan_type, ", ".join(sorted(index_names)) or None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--label",
        default="baseline_seqscan",
        help="label recorded for this benchmark run (default: baseline_seqscan)",
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
                "SELECT set_config('statement_timeout', %s, false)",
                (f"{args.statement_timeout_ms}ms",),
            )
            if args.label == "baseline_seqscan":
                cursor.execute("SET enable_seqscan = on")
                cursor.execute("SET enable_indexscan = off")
                cursor.execute("SET enable_bitmapscan = off")

            cursor.execute(
                """
                SELECT current_setting('server_version'),
                       current_setting('work_mem'),
                       current_setting('shared_buffers'),
                       current_setting('enable_seqscan'),
                       current_setting('enable_indexscan'),
                       current_setting('enable_bitmapscan'),
                       current_setting('statement_timeout')
                """
            )
            (
                pg_version,
                work_mem,
                shared_buffers,
                enable_seqscan,
                enable_indexscan,
                enable_bitmapscan,
                statement_timeout,
            ) = cursor.fetchone()
            settings = {
                "work_mem": work_mem,
                "shared_buffers": shared_buffers,
                "enable_seqscan": enable_seqscan,
                "enable_indexscan": enable_indexscan,
                "enable_bitmapscan": enable_bitmapscan,
                "statement_timeout": statement_timeout,
                "target_query_seconds": args.target_query_seconds,
                "max_iterations": args.max_iterations,
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

            for query_id, smarts in queries:
                for _ in range(WARMUP_RUNS):
                    try:
                        explain(cursor, smarts)
                    except psycopg.errors.QueryCanceled as error:
                        raise RuntimeError(
                            f"{query_id} exceeded the {statement_timeout} statement "
                            f"timeout during warm-up; partial results are retained "
                            f"in run {run_id}."
                        ) from error

                durations = []
                iteration = 1
                target_ms = args.target_query_seconds * 1000
                max_iterations = args.max_iterations
                while iteration <= max_iterations:
                    try:
                        document = explain(cursor, smarts)
                    except psycopg.errors.QueryCanceled as error:
                        raise RuntimeError(
                            f"{query_id} exceeded the {statement_timeout} statement "
                            f"timeout; partial results are retained in run {run_id}."
                        ) from error
                    plan = document["Plan"]
                    shared_hit, shared_read = buffer_totals(plan)
                    scan_type, index_name = plan_access(plan)
                    cursor.execute(
                        """
                        INSERT INTO bench.run_results
                            (run_id, query_id, iteration, exec_ms, plan_rows,
                             actual_rows, shared_hit, shared_read, scan_type,
                             index_name, planning_ms, plan_json)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        """,
                        (
                            run_id,
                            query_id,
                            iteration,
                            document["Execution Time"],
                            plan["Plan Rows"],
                            plan["Actual Rows"],
                            shared_hit,
                            shared_read,
                            scan_type,
                            index_name,
                            document["Planning Time"],
                            Jsonb(document) if iteration == 1 else None,
                        ),
                    )
                    durations.append(document["Execution Time"])

                    if iteration == PILOT_RUNS:
                        median_ms = max(statistics.median(durations), 1)
                        target_iterations = int(target_ms / median_ms)
                        max_iterations = max(
                            PILOT_RUNS,
                            min(args.max_iterations, target_iterations),
                        )
                        print(
                            f"{query_id}: {max_iterations} timed iterations "
                            f"(pilot median {median_ms:.3f} ms)"
                        )
                    iteration += 1

            summary = cursor.execute(SUMMARY_SQL, (run_id,)).fetchall()

    print(f"run_id={run_id}")
    print(
        "query_id\titerations\tmin_ms\tp50_ms\tiqr_ms\tmatches"
        "\tscan_type\tindex_name\tmax_shared_read"
    )
    for (
        query_id,
        iterations,
        min_ms,
        p50,
        iqr,
        matches,
        scan_type,
        index_name,
        max_shared_read,
    ) in summary:
        print(
            f"{query_id}\t{iterations}\t{min_ms}\t{p50}\t{iqr}\t{matches}"
            f"\t{scan_type}\t{index_name or '-'}\t{max_shared_read}"
        )


if __name__ == "__main__":
    main()
