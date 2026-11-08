CREATE EXTENSION IF NOT EXISTS rdkit;

CREATE TABLE molecules (
    row_idx bigint PRIMARY KEY,
    smiles text NOT NULL,
    label smallint NOT NULL CHECK (label IN (0, 1)),
    mol mol NOT NULL
);

CREATE TABLE ingest_rejects (
    row_idx bigint PRIMARY KEY,
    smiles text,
    label smallint,
    reject_reason text NOT NULL,
    rejected_at timestamptz NOT NULL DEFAULT now()
);

-- bbbp_stage is expected to retain the source row_idx, smiles, and label.
-- MATERIALIZED ensures each input SMILES is parsed once and reused for both inserts.
WITH parsed AS MATERIALIZED (
    SELECT
        row_idx,
        smiles,
        label,
        mol_from_smiles(smiles::cstring) AS mol
    FROM bbbp_stage
),
loaded AS (
    INSERT INTO molecules (row_idx, smiles, label, mol)
    SELECT row_idx, smiles, label, mol
    FROM parsed
    WHERE mol IS NOT NULL
    RETURNING row_idx
),
rejected AS (
    INSERT INTO ingest_rejects (row_idx, smiles, label, reject_reason)
    SELECT row_idx, smiles, label, 'mol_from_smiles returned NULL'
    FROM parsed
    WHERE mol IS NULL
    RETURNING row_idx
)
SELECT
    (SELECT count(*) FROM loaded) AS molecules_loaded,
    (SELECT count(*) FROM rejected) AS rows_rejected;
