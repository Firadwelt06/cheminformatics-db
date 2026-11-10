\set ON_ERROR_STOP on

DROP TABLE IF EXISTS bbbp_stage;

CREATE TABLE bbbp_stage (
    row_idx integer GENERATED ALWAYS AS IDENTITY (START WITH 0 MINVALUE 0) PRIMARY KEY,
    smiles  text     NOT NULL,
    label   smallint NOT NULL
);

COPY bbbp_stage (smiles, label) FROM '/data/bbbp.csv' WITH (FORMAT csv, HEADER true);
