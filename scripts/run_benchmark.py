#!/usr/bin/env python3
"""Run the query catalog benchmark against the local PostgreSQL database."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb


EXPECTED_MOLECULES = 1975
WARMUP_RUNS = 3
TIMED_RUNS = 20
DEFAULT_DSN = "postgresql://chem:chem_dev_pw@localhost:5432/chemdb"
SUMMARY_SQL = """
    SELECT query_id,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS p50,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY exec_ms) AS p95,
           max(actual_rows) AS matches
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


def explain(cursor: psycopg.Cursor[Any], query: str) -> dict[str, Any]:
    if not re.match(r"^\s*SELECT\b", query, re.IGNORECASE):
        raise ValueError(f"Catalog query must be a SELECT statement: {query!r}")

    statement = query.strip().removesuffix(";")
    if ";" in statement:
        raise ValueError(f"Catalog query must contain one statement: {query!r}")

    cursor.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {statement}")
    result = cursor.fetchone()[0]
    if isinstance(result, str):
        result = json.loads(result)
    return result[0]


def buffer_totals(plan: dict[str, Any]) -> tuple[int, int]:
    hits = plan.get("Shared Hit Blocks", 0)
    reads = plan.get("Shared Read Blocks", 0)
    for child in plan.get("Plans", []):
        child_hits, child_reads = buffer_totals(child)
        hits += child_hits
        reads += child_reads
    return hits, reads


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
    args = parser.parse_args()

    with psycopg.connect(args.dsn) as connection:
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

            if args.label == "baseline_seqscan":
                cursor.execute("SET LOCAL enable_seqscan = on")
                cursor.execute("SET LOCAL enable_indexscan = off")
                cursor.execute("SET LOCAL enable_bitmapscan = off")

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
            settings = {
                "work_mem": work_mem,
                "shared_buffers": shared_buffers,
                "enable_seqscan": enable_seqscan,
                "enable_indexscan": enable_indexscan,
                "enable_bitmapscan": enable_bitmapscan,
            }

            queries = cursor.execute(
                """
                SELECT query_id, sql_text
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

            for query_id, sql_text in queries:
                for _ in range(WARMUP_RUNS):
                    explain(cursor, sql_text)

                for iteration in range(1, TIMED_RUNS + 1):
                    document = explain(cursor, sql_text)
                    plan = document["Plan"]
                    shared_hit, shared_read = buffer_totals(plan)
                    cursor.execute(
                        """
                        INSERT INTO bench.run_results
                            (run_id, query_id, iteration, exec_ms, plan_rows,
                             actual_rows, shared_hit, shared_read, plan_json)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
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
                            Jsonb(document) if iteration == 1 else None,
                        ),
                    )

        connection.commit()

        with connection.cursor() as cursor:
            summary = cursor.execute(SUMMARY_SQL, (run_id,)).fetchall()

    print(f"run_id={run_id}")
    print("query_id\tp50_ms\tp95_ms\tmatches")
    for query_id, p50, p95, matches in summary:
        print(f"{query_id}\t{p50}\t{p95}\t{matches}")


if __name__ == "__main__":
    main()
