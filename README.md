# PostgreSQL + RDKit search benchmarks

This project measures molecular substructure and fingerprint-similarity search
with PostgreSQL 15 and the RDKit cartridge, using a pinned 2,039-row BBBP
artifact (1,975 distinct molecules).

## Headline findings

The full paired substructure run (run 46, `day3_paired`) interleaved sequential
and GiST-enabled plans, with randomized variant order. It used the default
30-second-per-query adaptive budget and recorded 1,380 successful observations
with no timed-out observations.

| Query | Pattern | Matches | Paired iterations | Median seq / GiST | GiST candidates | Removed by recheck |
|---|---|---:|---:|---:|---:|---:|
| Q1 | `[B]` | 1 | 78 | 56.22x | 31 | 30 |
| Q2 | `S(=O)(=O)N` | 57 | 100 | 27.25x | 84 | 27 |
| Q3 | `c1ccccc1` | 1,367 | 56 | 1.01x | 1,810 | 443 |
| Q4 | `C(=O)[OH]` | 201 | 56 | 1.38x | 1,285 | 1,084 |
| Q5 | `[#6]` | 1,974 | 100 | 0.92x | 1,974 | 0 |
| Q6 | `[Se]` | 0 | 100 | 1.22x | 1,400 | 1,400 |
| Q7 | `[Se]C` | 0 | 100 | 1.18x | 1,400 | 1,400 |
| Q8 | `C[Se]C` | 0 | 100 | 1.20x | 1,400 | 1,400 |

Ratios are medians of per-iteration `seq_ms / gist_ms`; above 1 means the
sequential plan was slower. On this dataset, GiST substantially helped the
rare Q1/Q2 patterns, was near-neutral or slower for common Q3/Q5, and showed a
smaller measured improvement for Q4. The Q6–Q8 experiment did not reduce the
false-candidate count: each zero-match selenium pattern still produced 1,400
candidates, all removed by heap recheck—about 71% of the table.

The GiST `mol` plans estimate 2 rows for every SMARTS. Q3 actually matches
1,367, illustrating the planner's selectivity error. These are measurements
from one machine and a small dataset, not large-scale performance promises.
Repeated baseline p50s differed by 29–216% for Q1–Q5; interleaved pairing
reduces separate-run timing confounds but cannot eliminate system noise.

No single per-row parsing-versus-stored-`mol` timing is reported: the saved
evidence does not preserve enough query/run provenance to reconcile earlier
figures. The paired per-query results above are the supported comparison.
Short validation tables and the historical separate-run measurements are in
the [benchmark journal](docs/journal/benchmark-history.md).

## Quickstart

Requirements: Windows, Docker Desktop with WSL2, Docker Compose v2, PowerShell
7+, Python, and Git. The BBBP CSV is not included because its upstream license
is marked unknown. Download the pinned, checksummed artifact first:

```powershell
.\scripts\Download-BBBP.ps1
```

Start PostgreSQL and load the data:

```powershell
docker compose up --build -d
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/01_schema.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/02_stage_bbbp.sql
$hash = (Get-FileHash .\data\bbbp.csv -Algorithm SHA256).Hash.ToLowerInvariant()
docker compose exec -T db psql -v ON_ERROR_STOP=1 -v "file_sha256=$hash" -U chem -d chemdb -f /sql/02_load_bbbp.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/05_build_mol_gist_index.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/03_bench_schema.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/04_seed_query_catalog.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/06_fingerprint_index.sql
py -m pip install -r requirements.txt
```

Run an interleaved benchmark (defaults: up to 100 timed iterations per query,
about 30 seconds of timed work per query, and a 30-second per-statement
timeout):

```powershell
py .\scripts\run_benchmark.py --variants --label day3_paired
```

The runner checks for 1,975 distinct BBBP molecules before recording a run.
Successful rows in `bench.run_results` include plan estimates, actual matches,
buffer counts, candidates, `rows_removed_by_recheck`, and
`lossy_heap_blocks`. A statement timeout is recorded as `status = 'timeout'`
with `timeout_ms` and `error_message`; `exec_ms` and plan fields remain null,
and timed-out samples are excluded from latency ratios.

For fingerprint similarity, the setup script persists Morgan bit fingerprints
in `molecules.fingerprint` (`bfp`) and creates the `gist_bfp_ops` index. The
runnable aspirin example uses a Tanimoto threshold of 0.3:

```powershell
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/queries/similarity_top_10.sql
```

On the 1,975-row table, the example returned ten top-ranked structures. The
separate plan check at `rdkit.tanimoto_threshold = 0.3` used
`molecules_fingerprint_gist` via a Bitmap Index Scan, returned 28 candidates,
and removed none by recheck. That check disables sequential scans to verify
index eligibility; it is not evidence that the planner should prefer the index
for every table size or threshold. The fingerprint index occupied 272 kB in
this run. See [`sql/07_explain_fingerprint_similarity.sql`](sql/07_explain_fingerprint_similarity.sql)
for the reproducible plan check.

`scripts\Verify-Rebuild.ps1` performs a destructive clean rebuild: it removes
the Compose named volumes, loads BBBP, creates the benchmark catalog and both
GiST indexes, executes a one-iteration paired benchmark smoke test, and
compares `pg_dump --schema-only` output from the rebuilt and previously
running databases. Run it only when discarding the current database volume is
acceptable; `-WhatIf` previews the action.

## Caveats and next step

- The paired measurements cover 1,975 distinct structures on one machine.
  Prior repeat baselines differed by 29–216% for Q1–Q5; pairing is the
  mitigation, not a guarantee of low variance.
- A zero-match substructure query can still return many GiST signature
  candidates that the heap must recheck.
- The similarity plan demonstrates an available indexed path, not a
  large-scale speedup. The current example uses Morgan bit fingerprints and
  an explicit threshold; its index and threshold behavior should be measured
  again on larger data.
- The pinned BBBP artifact has 2,039 source rows, not the 2,053 compounds
  reported in the original MoleculeNet paper. See [Wu et al. (2018)](https://pmc.ncbi.nlm.nih.gov/articles/PMC5868307/).
- **Week 3:** evaluate a 10-million-row workload and report throughput,
  storage, planner estimates, and paired timings.

## License and data

The repository's code and documentation are licensed under the [MIT License](LICENSE).
That license does not apply to the BBBP CSV: the upstream artifact's license
is unknown, so the file is downloaded locally and excluded from Git. Consult
the upstream dataset and paper for source-specific citation and reuse terms.
