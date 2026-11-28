# Substructure search over molecules in PostgreSQL: what the planner can't see

This project tests a practical tradeoff in cheminformatics databases: parsing SMILES at query time is slower than storing RDKit's parsed `mol` value, but stored structures take substantially more space—and PostgreSQL's planner does not accurately estimate RDKit substructure predicates.

| Headline result | Measurement |
|---|---:|
| Parse SMILES per row | ~0.30–0.35 ms/row |
| Search using stored `mol` | ~0.06 ms/row (about 5–6× faster) |
| Storage per value | 357 B for `mol` vs 52 B for SMILES (~6.9× more) |
| Planner estimate for `@>` | 2 rows estimated vs 1,367 actual |

These are early measurements on one machine and a 2,039-row dataset. See the [findings](#findings-and-caveats) and [limitations](#limitations) for the caveats.

## Quickstart

Requirements: Windows, Docker Desktop with the WSL2 backend, Docker Compose v2, and PowerShell 7 or later. A local `.env` file is optional; copy `.env.example` to `.env` and adjust the development-only credentials if desired. Docker Compose reads `.env` automatically.

The BBBP CSV is not distributed by this repository because its upstream license is marked unknown. On a fresh checkout, download the [pinned 2,039-row Hugging Face artifact](https://huggingface.co/datasets/scikit-fingerprints/MoleculeNet_BBBP/tree/86db3f465c006b230b1e5af9032a1e05be4db618):

```powershell
.\scripts\Download-BBBP.ps1
```

The downloader verifies the pinned file checksum, its `SMILES,label` columns, and the 2,039-row count; it refuses to overwrite an existing local file unless `-Force` is supplied. This pinned artifact's row values and ordering match the local baseline. The loader records its URL, revision, citations, unknown license, and the downloaded file's checksum in `datasets`.

The one-command clean rebuild is:

```powershell
.\scripts\Verify-Rebuild.ps1
```

It rebuilds the image and database from scratch, waits for PostgreSQL, executes the three SQL files with `ON_ERROR_STOP`, and verifies `2039|2039|0|1975` (staged, loaded, rejected, distinct molecules). It deletes the Compose named volumes via `docker compose down -v`; use `-WhatIf` to preview or `-Confirm:$false` to suppress the confirmation prompt.

To run the SQL manually against a fresh database instead, start Compose and run:

```powershell
docker compose up --build -d
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/01_schema.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/02_stage_bbbp.sql
$hash = (Get-FileHash .\data\bbbp.csv -Algorithm SHA256).Hash.ToLowerInvariant()
docker compose exec -T db psql -v ON_ERROR_STOP=1 -v "file_sha256=$hash" -U chem -d chemdb -f /sql/02_load_bbbp.sql
```

To set up the optional benchmark query catalog after loading BBBP, run:

```powershell
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/03_bench_schema.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/04_seed_query_catalog.sql
```

Q1 uses boron (`[B]`), which matches one BBBP molecule. Q6 retains selenium
(`[Se]`), which matches zero molecules and records that as the rare-pattern
case.

## Running the baseline benchmark

After loading BBBP and setting up the benchmark schema and query catalog above,
install the Python dependency and run the benchmark from the repository root:

```powershell
py -m pip install -r requirements.txt
py .\scripts\run_benchmark.py --variants --label day2_paired
```

By default, the runner connects to the local Compose database with the development
credentials. Set `DATABASE_URL` or pass `--dsn` if your connection settings differ.
It first verifies that BBBP contains exactly 1,975 distinct loaded molecules;
otherwise it stops without recording a run. By default, it runs the `gist`
variant alone; pass `--variants` to interleave paired `seq` and `gist` plans
inside every iteration in randomized order. Each query gets three warm-ups per
variant and one timed pilot pair, followed by an adaptive number of timed
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` runs. The default budget is about 30
seconds per query, capped at 100 runs; a 30-second `statement_timeout` bounds
each statement. Override these with `--target-query-seconds`,
`--max-iterations`, and `--statement-timeout-ms`. Timed rows include scan/index
names, planning time, row estimates and buffer counts. The descriptive `--label`
does not control planner settings. The `seq` variant disables index and bitmap
scans; `gist` enables both and lets the planner choose. With `--variants`, the
runner reports per-variant min, p50, IQR and matches, and the median of
per-iteration `seq / gist` execution-time ratios.

### Pre-index baseline and predictions

Before creating a GiST index, run 37 passed the 1,975-molecule assertion. All
six plans were `Seq Scan`, had no `Gather`, estimated 2 rows, and recorded 0
shared reads. Actual matches were Q1=1, Q2=57, Q3=1,367, Q4=201, Q5=1,974,
and Q6=0. The molecule without carbon is `mol_id=1709`, canonical SMILES
`[N-]=[N+]=O`, which is nitrous oxide. Its BBBP record is row 2033 with label
1 (BBBP-positive). Q4's `[OH]` SMARTS explicitly constrains the hydroxyl
hydrogen, so query complexity as well as selectivity can affect matcher cost.

The repeat baseline p50s differed substantially between runs 36 and 37
(29–216% for Q1–Q5), despite 0 shared reads. Treat this as observed timing
noise; compare later indexed results against repeated baselines, not a single
latency number.

Predictions to compare after the index is added: the planner will choose a GiST
path for all six because it estimates 2 rows for every SMARTS. Q1 and Q6 should
benefit most; Q2 and Q4 should improve; Q3 and especially Q5 may get slower
because the index will still return many candidates to recheck (Q5 matches
1,974 of 1,975). Q5 is the strongest test of whether a low row estimate leads
the planner to choose a poor index plan.

### Day 2: GiST index results

The index was created **after** loading BBBP using
`CREATE INDEX CONCURRENTLY molecules_mol_gist ON molecules USING gist (mol);`.
On PostgreSQL 15.20 with RDKit extension 4.3.0 / `rdkit_version()` 0.73.0,
building it took 7.156 seconds wall-clock from PowerShell (including `docker
compose exec` startup) and occupied 860,160 bytes (840 kB). The table had 1,975
distinct BBBP molecules. Check the index size with:

```sql
SELECT pg_relation_size('molecules_mol_gist') AS size_bytes,
       pg_size_pretty(pg_relation_size('molecules_mol_gist')) AS size_pretty;
```

To capture all six catalog queries with timing collection disabled:

```powershell
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U chem -d chemdb -f /sql/05_explain_indexed_queries.sql
```

For paired benchmarks use one run, not two sequential calls:

```powershell
py .\scripts\run_benchmark.py --variants --label day2_paired --target-query-seconds 1 --max-iterations 10
```

Run 40 validated the interleaved implementation with a brief adaptive budget.
Run 41 smoke-tested the final version (one pair per query). Both passed the
1,975-row assertion and randomized `seq` / `gist` order within each iteration.
The median ratio is computed from paired per-iteration `seq_ms / gist_ms`
values, not by dividing variant medians. These short validation runs are not
reliable performance estimates.

| Query | Paired iterations | Median seq / gist ratio |
|---|---:|---:|
| Q1 | 10 | 37.17x |
| Q2 | 10 | 16.88x |
| Q3 | 7 | 1.19x |
| Q4 | 6 | 1.22x |
| Q5 | 2 | 0.56x |
| Q6 | 4 | 0.87x |

Final code smoke test, run 41 (one paired iteration each):

| Query | Median seq / gist ratio |
|---|---:|
| Q1 | 22.83x |
| Q2 | 19.13x |
| Q3 | 0.84x |
| Q4 | 2.78x |
| Q5 | 0.66x |
| Q6 | 1.24x |

The original runs 38 and 39 used separate invocations, so their ratio-of-medians
table below is historical and not an interleaved paired measurement. For each
iteration the runner stores one row per variant. The result-table primary key is
`(run_id, query_id, iteration, variant)`, and historical rows were migrated to
`seq` or `gist` based on their run label. For the ratio output, values above 1
mean the sequential scan took longer than the GiST-enabled plan.

| Query | Existing prediction (unchanged) | Actual plan and separate-run p50 comparison (historical) |
|---|---|---|
| Q1 | GiST chosen; among the largest improvements. | Bitmap Heap Scan using `molecules_mol_gist`; 27.68x faster. |
| Q2 | GiST chosen; improves. | Bitmap Heap Scan using `molecules_mol_gist`; 24.00x faster. |
| Q3 | GiST chosen; may get slower. | Bitmap Heap Scan using `molecules_mol_gist`; 1.10x faster in this pair (small change; noise remains relevant). |
| Q4 | GiST chosen; improves. | Bitmap Heap Scan using `molecules_mol_gist`; 1.49x faster. |
| Q5 | GiST chosen; may get slower, especially. | Bitmap Heap Scan using `molecules_mol_gist`; 1.11x faster in this pair, but reads more shared buffers than the sequential scan. |
| Q6 | GiST chosen; among the largest improvements. | Bitmap Heap Scan using `molecules_mol_gist`; 1.27x faster, but 1,400 false-positive candidates were rechecked. |

| Query | Run 38 baseline p50 (ms) | Run 39 GiST p50 (ms) | Ratio of p50s (not paired) | Matches |
|---|---:|---:|---:|---:|
| Q1 | 68.3465 | 2.4695 | 27.68x | 1 |
| Q2 | 70.8260 | 2.9510 | 24.00x | 57 |
| Q3 | 77.1645 | 70.0805 | 1.10x | 1,367 |
| Q4 | 76.7535 | 51.6275 | 1.49x | 201 |
| Q5 | 69.8945 | 63.2225 | 1.11x | 1,974 |
| Q6 | 67.3545 | 53.0105 | 1.27x | 0 |

All six indexed plans were `Bitmap Index Scan` → `Bitmap Heap Scan`, with a
`Recheck Cond`; the planner estimated 2 rows for every SMARTS. Q5's 1,974
actual matches are **987x** its estimate (1,974 / 2). For Q6, the index did not
produce zero candidates: the Bitmap Index Scan returned 1,400 candidates, all
removed by the heap recheck (`Rows Removed by Index Recheck: 1400`). Thus this
zero-match SMARTS is not a no-recheck best case for this GiST signature index.
The separate-run comparison showed a small Q3 improvement rather than a
slowdown, but it was only about 9%, so timing noise and the small dataset limit
that conclusion.

| Query | Plan rows | Bitmap index candidates | Actual rows | Rows removed by recheck |
|---|---:|---:|---:|---:|
| Q1 | 2 | 31 | 1 | 30 |
| Q2 | 2 | 84 | 57 | 27 |
| Q3 | 2 | 1,810 | 1,367 | 443 |
| Q4 | 2 | 1,285 | 201 | 1,084 |
| Q5 | 2 | 1,974 | 1,974 | 0 |
| Q6 | 2 | 1,400 | 0 | 1,400 |

The `mol_id=1709` label and indexed plan demonstrate why assumptions based on
molecule size or SMARTS selectivity should be verified against the actual data
and access method.

To reproduce the summary for a particular run, substitute the printed ID:

```sql
SELECT query_id,
       variant,
       min(exec_ms) AS min_ms,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS p50,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY exec_ms)
         - percentile_cont(0.25) WITHIN GROUP (ORDER BY exec_ms) AS iqr_ms,
       max(actual_rows) AS matches,
       mode() WITHIN GROUP (ORDER BY scan_type) AS scan_type,
       max(planning_ms) AS planning_ms,
       max(shared_read) AS max_shared_read
FROM bench.run_results
WHERE run_id = 40
GROUP BY query_id, variant
ORDER BY query_id, variant;
```

To calculate the paired ratios directly for another run, use:

```sql
WITH paired AS (
    SELECT query_id, iteration,
           max(exec_ms) FILTER (WHERE variant = 'seq') AS seq_ms,
           max(exec_ms) FILTER (WHERE variant = 'gist') AS gist_ms
    FROM bench.run_results
    WHERE run_id = 40 AND variant IN ('seq', 'gist')
    GROUP BY query_id, iteration
    HAVING count(*) FILTER (WHERE variant = 'seq') = 1
       AND count(*) FILTER (WHERE variant = 'gist') = 1
)
SELECT query_id,
       count(*) AS paired_iterations,
       percentile_cont(0.5) WITHIN GROUP (
           ORDER BY seq_ms / NULLIF(gist_ms, 0)
       ) AS median_seq_over_gist_ratio
FROM paired
GROUP BY query_id
ORDER BY query_id;
```

Manual commands above show the default credentials; use matching values from `.env` if you customized them. The schema is a first-run script, not a migration. The named `pgdata` volume preserves the database when the container is recreated; do not run `docker compose down -v` unless you intend to discard it.

## Architecture

![Earlier schema diagram showing molecules, dataset records, and rejected input rows.](docs/schema-diagram.png)

`molecules` stores one parsed structure per canonical SMILES, while `dataset_records` stores each source row and its annotations. The `datasets` registry records source URL, citation, license, version, checksum, and load time; foreign keys prevent records or rejects from referring to a misspelled dataset. `ingest_rejects` retains invalid or empty structures with their source row and reason.

The `v_molecule_identity` view computes molecular formula and average molecular weight on demand rather than widening every molecule row. InChIKey is not stored; check whether the installed cartridge provides an InChI function before adding an on-demand projection. The `v_molecule_fingerprints` view exposes Morgan bit fingerprints for similarity queries. Quality views include `v_label_balance`, `v_duplicate_groups`, `v_label_conflicts`, and `v_load_summary`.

Runnable examples are in [`sql/queries/`](sql/queries/): the benzene substructure count and a top-10 Tanimoto similarity ranking for an aspirin query. The similarity example computes Morgan fingerprints on demand and is intended as a correctness/example query, not an indexed large-scale search. Run them with `psql -f` after the database is loaded.

## Findings and caveats

| Measured claim | Caveat |
|---|---|
| Parsing SMILES per row costs about 0.30–0.35 ms/row; querying a stored `mol` costs about 0.06 ms/row (roughly 5–6× faster). | A small-dataset, single-machine microbenchmark; timings vary by query, hardware, and run. |
| A stored `mol` value uses about 357 B versus 52 B for the SMILES value (~6.9× more storage). | Per-value measurements, not total table/index size; PostgreSQL row and index overhead are additional. |
| The `@>` substructure operator uses PostgreSQL's generic `contsel` selectivity estimator: the plan estimates 0.1% of rows (`rows=2`) where 1,367 match. The cartridge functions are also priced at `procost = 1`. | The estimate and function cost are for the observed plan and installed extension; they are not a guarantee about every predicate or query. |
| The 2,039-row BBBP artifact used for the baseline produced 0 unparseable or empty-molecule rejects and 1,975 distinct molecules. | The original MoleculeNet paper's Table 1 reports 2,053 BBBP compounds, not 2,050. The paper's benchmark count and this normalized artifact are not the same version/count; record the exact source artifact when comparing results. ([Wu et al., 2018, Table 1](https://pmc.ncbi.nlm.nih.gov/articles/PMC5868307/)) |
| There are 64 duplicate records across 60 molecule groups; 10 groups contain conflicting labels. | Duplicate groups are based on the canonicalized molecule identity, not byte-identical input SMILES. |
| About 76.5% of labels are positive. ROC-AUC is the MoleculeNet-recommended metric for BBBP; accuracy alone can be misleading with this class imbalance. | Keep the split strategy fixed and report class counts; a metric alone does not address leakage or split bias. |
| RDKit parses an empty SMILES string as a valid zero-atom molecule. | A `mol IS NOT NULL` check alone would admit it. The loader also checks atom count and records empty structures in `ingest_rejects`. |

## Environment and reproducibility

- **Host:** Windows with Docker Desktop using the WSL2 backend.
- **Database:** PostgreSQL 15 (`postgres:15-bookworm`).
- **RDKit:** the PostgreSQL RDKit cartridge is installed from Debian's `postgresql-15-rdkit` package in [docker/Dockerfile](docker/Dockerfile). The runtime `rdkit_version()` output observed for this setup is `0.73.0`; retain that literal output in benchmark notes rather than assuming it is the upstream RDKit release number. The package is not version-pinned in the Dockerfile, so a future image build may install a different package revision.
- **Persistent database storage:** Compose uses a named `pgdata` volume for `/var/lib/postgresql/data`. Keeping PostgreSQL's data directory in a Docker-managed volume avoids binding the live database files to a Windows/WSL workspace path and lets the database survive container replacement.
- **Shared memory:** `shm_size: 1g` enlarges the container's `/dev/shm` beyond Docker's small default. PostgreSQL uses shared memory for database operations; the larger allocation avoids an unnecessarily tight container limit as query and worker needs grow.
- **Dataset artifact:** `scripts/Download-BBBP.ps1` fetches the pinned `scikit-fingerprints/MoleculeNet_BBBP` CSV revision. Its 2,039 rows are not the same count as the 2,053 compounds reported in the primary MoleculeNet paper; record the exact artifact and checksum when comparing results. The dataset card marks its license unknown, so the CSV is ignored by Git.

To confirm the runtime version after startup:

```powershell
docker compose exec -T db psql -U chem -d chemdb -c "SELECT version(); SELECT rdkit_version();"
```

## Data validation

Validation happens in two layers.

Schema constraints: NOT NULL on SMILES and labels, UNIQUE canonical SMILES
per molecule, a foreign key from records to molecules, and composite primary
keys that make loads re-runnable.

Loader checks ([sql/02_load_bbbp.sql](sql/02_load_bbbp.sql)):
- A SMILES that fails RDKit parsing or sanitization is quarantined in
  ingest_rejects as parse_failed.
- A SMILES that parses to a molecule with zero atoms is quarantined as
  empty_molecule.
- Duplicate structures are collapsed by canonical SMILES; every source record
  is preserved.
- The load aborts and rolls back if staged rows do not equal loaded plus
  rejected rows.

Not validated (yet): label values, salts/charge/stereo standardization, and
label conflicts. Conflicts are reported, not resolved: 10 molecules in BBBP
carry conflicting labels.
Check which identity and fingerprint functions are available in the installed cartridge with `\df *mol*`, `\df *inchi*`, `\df *fp*`, and `\df *tanimoto*`. In the observed environment, `\dx` reported extension version `4.3.0` and `rdkit_version()` returned `0.73.0`; those values are recorded as observed runtime output, not inferred upstream release versions.

## Limitations

- The current dataset has only about 2,000 rows.
- Measurements come from one machine; expect approximately ±10–15% timing noise.
- The GiST substructure index was measured only on the small BBBP dataset; the results do not establish performance at larger scale.
- The current findings are not a scale-out or production workload evaluation.

## Roadmap

- **Week 2:** build and evaluate RDKit substructure indexes.
- **Week 2:** test PostgreSQL parallel workers and measure their effect on the search workload.
- **Week 2:** run the benchmark at 10 million rows and report throughput, storage, and planner estimates.

## Project structure

- `docker/` — PostgreSQL image setup.
- `sql/` — schema, staging, and BBBP load scripts.
- `data/` — local, Git-ignored BBBP dataset artifact.
- `scripts/` — dataset download and destructive clean-rebuild verification workflows.
- `docs/` — project journal, roadmap, and decision notes.
- [Publishing kit](docs/publishing-kit.md) — article, carousel, Shorts, and visual assets.

## License

This repository is intentionally kept lightweight and open for rapid iteration.
