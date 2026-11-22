CREATE SCHEMA IF NOT EXISTS bench;

CREATE TABLE bench.query_catalog (
    query_id     text PRIMARY KEY,
    description  text NOT NULL,
    sql_text     text NOT NULL   -- uses a %(smarts)s style or fixed literal
);

CREATE TABLE bench.runs (
    run_id       bigserial PRIMARY KEY,
    started_at   timestamptz NOT NULL DEFAULT now(),
    label        text NOT NULL,          -- e.g. 'baseline_seqscan', 'gist_mol'
    git_sha      text,
    pg_version   text,
    row_count    bigint,
    settings     jsonb                   -- work_mem, shared_buffers, etc.
);

CREATE TABLE bench.run_results (
    run_id       bigint REFERENCES bench.runs,
    query_id     text   REFERENCES bench.query_catalog,
    iteration    int    NOT NULL,
    exec_ms      numeric NOT NULL,
    plan_rows    bigint,                 -- planner's estimate
    actual_rows  bigint,
    shared_hit   bigint,
    shared_read  bigint,
    plan_json    jsonb,                  -- keep for iteration 1 only
    PRIMARY KEY (run_id, query_id, iteration)
);