# Benchmark journal

This file holds the day-by-day measurements and short validation runs that are
too provisional for the project README. Short runs are checks of the harness,
not performance evidence.

## Pre-index baseline

Run 37 passed the 1,975-molecule assertion. All six plans were `Seq Scan`, had
no `Gather`, estimated 2 rows, and recorded 0 shared reads. Actual matches were
Q1=1, Q2=57, Q3=1,367, Q4=201, Q5=1,974, and Q6=0. The molecule without
carbon is `mol_id=1709`, canonical SMILES `[N-]=[N+]=O` (nitrous oxide); its
BBBP record is row 2033 with label 1.

The repeat baseline p50s differed substantially between runs 36 and 37
(29–216% for Q1–Q5), despite 0 shared reads. This is measured run-to-run
variation on one small dataset and machine, not a general timing-noise bound.

## Day 2: substructure GiST

The index was created after loading BBBP using
`CREATE INDEX CONCURRENTLY molecules_mol_gist ON molecules USING gist (mol);`.
On PostgreSQL 15.20 with RDKit extension 4.3.0 / `rdkit_version()` 0.73.0,
building it took 7.156 seconds wall-clock from PowerShell (including
`docker compose exec` startup) and occupied 860,160 bytes (840 kB). The table
had 1,975 distinct BBBP molecules.

The plans were all `Bitmap Index Scan` → `Bitmap Heap Scan`, with a `Recheck
Cond`; the planner estimated 2 rows for every SMARTS. The recorded candidate
counts below came from a plan inspection, not from the original benchmark
harness.

| Query | Plan rows | Bitmap index candidates | Actual rows | Rows removed by recheck |
|---|---:|---:|---:|---:|
| Q1 | 2 | 31 | 1 | 30 |
| Q2 | 2 | 84 | 57 | 27 |
| Q3 | 2 | 1,810 | 1,367 | 443 |
| Q4 | 2 | 1,285 | 201 | 1,084 |
| Q5 | 2 | 1,974 | 1,974 | 0 |
| Q6 | 2 | 1,400 | 0 | 1,400 |

Q5's 1,974 actual matches are 987x its estimate (1,974 / 2). For Q6, the
index returned 1,400 candidates, all removed by the heap recheck; 1,400 is
about 71% of the 1,975-row table. Thus this zero-match SMARTS was not a
no-recheck best case for this GiST signature index.

### Separate-run comparison (runs 38 and 39; historical)

These were separate invocations, so the ratio of p50s is not an interleaved
paired measurement. The Q5 buffer claim from the original README is omitted:
the old measurements were affected by a double-counting bug and should not be
used to claim higher shared-buffer usage.

| Query | Run 38 baseline p50 (ms) | Run 39 GiST p50 (ms) | Ratio of p50s (not paired) | Matches |
|---|---:|---:|---:|---:|
| Q1 | 68.3465 | 2.4695 | 27.68x | 1 |
| Q2 | 70.8260 | 2.9510 | 24.00x | 57 |
| Q3 | 77.1645 | 70.0805 | 1.10x | 1,367 |
| Q4 | 76.7535 | 51.6275 | 1.49x | 201 |
| Q5 | 69.8945 | 63.2225 | 1.11x | 1,974 |
| Q6 | 67.3545 | 53.0105 | 1.27x | 0 |

### Interleaving validation (runs 40 and 41; not performance runs)

Run 40 validated interleaved ordering with a short adaptive budget. Run 41
smoke-tested the final version (one paired iteration per query). Both passed
the 1,975-row assertion. Their tiny sample sizes are not estimates of stable
performance; run 41 has only one pair for each query.

| Query | Run 40 paired iterations | Run 40 median seq / gist ratio |
|---|---:|---:|
| Q1 | 10 | 37.17x |
| Q2 | 10 | 16.88x |
| Q3 | 7 | 1.19x |
| Q4 | 6 | 1.22x |
| Q5 | 2 | 0.56x |
| Q6 | 4 | 0.87x |

| Query | Run 41 median seq / gist ratio (one pair) |
|---|---:|
| Q1 | 22.83x |
| Q2 | 19.13x |
| Q3 | 0.84x |
| Q4 | 2.78x |
| Q5 | 0.66x |
| Q6 | 1.24x |

The runner computes the median of per-iteration `seq / gist` execution-time
ratios. Values above 1 mean the sequential scan took longer.

## Day 3

Day 3 adds Q7/Q8 to test selenium-carbon patterns against Q6's signature
collisions, stores per-row Morgan bit fingerprints with a GiST index, and
extends the benchmark records with timeout outcomes and bitmap recheck metrics.

The benchmark harness was exercised with a 1 ms statement timeout (run 45):
all 16 timed variant executions were retained as timeout rows, and the script
completed. This is a behavior check only, not a timing result.
Run 47 exercised the one-pair rebuild smoke command after the schema changes;
its single-pair timings are validation output, not performance evidence.

### Full paired run 46 (`day3_paired`)

This run used the default 30-second/query adaptive budget, up to 100 iterations,
and 30-second statement timeouts. It completed with 1,380 successful
observations and no timed-out observations. Candidate/recheck/lossy values
below are from the extended harness and its saved benchmark rows.

| Query | Matches | Paired iterations | Median seq / gist | GiST candidates | Removed by recheck | Lossy heap blocks |
|---|---:|---:|---:|---:|---:|---:|
| Q1 `[B]` | 1 | 78 | 56.22x | 31 | 30 | 0 |
| Q2 sulfonamide | 57 | 100 | 27.25x | 84 | 27 | 0 |
| Q3 benzene | 1,367 | 56 | 1.01x | 1,810 | 443 | 0 |
| Q4 carboxylic acid | 201 | 56 | 1.38x | 1,285 | 1,084 | 0 |
| Q5 carbon | 1,974 | 100 | 0.92x | 1,974 | 0 | 0 |
| Q6 `[Se]` | 0 | 100 | 1.22x | 1,400 | 1,400 | 0 |
| Q7 `[Se]C` | 0 | 100 | 1.18x | 1,400 | 1,400 | 0 |
| Q8 `C[Se]C` | 0 | 100 | 1.20x | 1,400 | 1,400 | 0 |

Appending carbon constraints in Q7/Q8 did not reduce the signature candidates
for this dataset/index; all three zero-match selenium queries had the same
1,400 candidates and recheck removals.

The persistent Morgan bit fingerprints populated all 1,975 molecules and
produced 1,951 distinct fingerprints. The GiST fingerprint index occupied
272 kB. The aspirin example at threshold 0.3 returned ten results. With
sequential scans disabled to check index eligibility, `EXPLAIN (ANALYZE,
BUFFERS)` used `molecules_fingerprint_gist` via a Bitmap Index Scan, returned
28 candidates, and removed zero by recheck. This verifies an available index
path, not a measured large-scale speedup.

The former README per-row timings (~0.06 and ~0.036 ms/row) do not have enough
preserved query/run provenance to reconcile. They have been removed from the
headline claims rather than implying they measure the same query.
