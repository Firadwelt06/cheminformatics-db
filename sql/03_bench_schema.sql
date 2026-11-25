CREATE SCHEMA IF NOT EXISTS bench;

CREATE TABLE IF NOT EXISTS bench.query_catalog (
    query_id     text PRIMARY KEY,
    description  text NOT NULL,
    smarts       text NOT NULL
);

ALTER TABLE bench.query_catalog
    ADD COLUMN IF NOT EXISTS smarts text;
ALTER TABLE bench.query_catalog
    ADD COLUMN IF NOT EXISTS sql_text text;

UPDATE bench.query_catalog
SET smarts = (regexp_match(
    sql_text,
    $$mol\s*@>\s*'([^']*)'\s*::qmol$$
))[1]
WHERE smarts IS NULL
  AND sql_text IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM bench.query_catalog WHERE smarts IS NULL) THEN
        RAISE EXCEPTION 'could not migrate every query_catalog row to a SMARTS pattern';
    END IF;
END $$;

ALTER TABLE bench.query_catalog
    ALTER COLUMN smarts SET NOT NULL;
ALTER TABLE bench.query_catalog
    DROP COLUMN IF EXISTS sql_text;

CREATE TABLE IF NOT EXISTS bench.runs (
    run_id       bigserial PRIMARY KEY,
    started_at   timestamptz NOT NULL DEFAULT now(),
    label        text NOT NULL,          -- e.g. 'baseline_seqscan', 'gist_mol'
    git_sha      text,
    pg_version   text,
    row_count    bigint,
    settings     jsonb                   -- work_mem, shared_buffers, etc.
);

CREATE TABLE IF NOT EXISTS bench.run_results (
    run_id       bigint REFERENCES bench.runs,
    query_id     text   REFERENCES bench.query_catalog,
    iteration    int    NOT NULL,
    exec_ms      numeric NOT NULL,
    plan_rows    bigint,                 -- planner's estimate
    actual_rows  bigint,
    shared_hit   bigint,
    shared_read  bigint,
    scan_type    text,
    index_name   text,
    planning_ms  numeric,
    plan_json    jsonb,                  -- keep for iteration 1 only
    PRIMARY KEY (run_id, query_id, iteration)
);

ALTER TABLE bench.run_results
    ADD COLUMN IF NOT EXISTS scan_type text;
ALTER TABLE bench.run_results
    ADD COLUMN IF NOT EXISTS index_name text;
ALTER TABLE bench.run_results
    ADD COLUMN IF NOT EXISTS planning_ms numeric;