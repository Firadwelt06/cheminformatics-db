\set ON_ERROR_STOP on
\pset pager off
SET enable_indexscan = off;
SET enable_bitmapscan = off;

-- Run the EXPLAIN queries here (Variant A)
SELECT format(
    'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT mol_id FROM molecules WHERE mol @> %L::qmol;',
    smarts
) AS explain_sql
FROM bench.query_catalog
ORDER BY query_id
\gexec

RESET enable_indexscan;
RESET enable_bitmapscan;

-- Run the same EXPLAIN queries here (Variant B)
SELECT format(
    'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT mol_id FROM molecules WHERE mol @> %L::qmol;',
    smarts
) AS explain_sql
FROM bench.query_catalog
ORDER BY query_id
\gexec
