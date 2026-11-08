CREATE EXTENSION IF NOT EXISTS rdkit;

-- One row per distinct molecule (immutable, expensive columns)
CREATE TABLE molecules (
    mol_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canonical_smiles text NOT NULL,
    mol              mol  NOT NULL,
    CONSTRAINT molecules_canonical_smiles_key UNIQUE (canonical_smiles)
);

-- One row per dataset record (cheap, mutable annotations)
CREATE TABLE dataset_records (
    dataset    text     NOT NULL,
    row_idx    integer  NOT NULL,
    mol_id     bigint   NOT NULL REFERENCES molecules (mol_id),
    raw_smiles text     NOT NULL,
    label      smallint NOT NULL,
    PRIMARY KEY (dataset, row_idx)
);
CREATE INDEX dataset_records_mol_id_idx ON dataset_records (mol_id);  -- Postgres doesn't index FKs for you

CREATE TABLE ingest_rejects (
    dataset       text        NOT NULL,
    row_idx       integer     NOT NULL,
    raw_smiles    text,
    label         smallint,
    reject_reason text        NOT NULL,
    rejected_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dataset, row_idx)
);

BEGIN;

CREATE TEMP TABLE bbbp_parsed ON COMMIT DROP AS
SELECT row_idx, smiles, label, mol,
       CASE WHEN mol IS NOT NULL THEN mol_to_smiles(mol)::text END AS canon
FROM (
    SELECT row_idx, smiles, label, mol_from_smiles(smiles::cstring) AS mol
    FROM bbbp_stage
) s;                                   -- the only place we parse

INSERT INTO ingest_rejects (dataset, row_idx, raw_smiles, label, reject_reason)
SELECT 'bbbp', row_idx, smiles, label, 'mol_from_smiles returned NULL'
FROM bbbp_parsed WHERE mol IS NULL;

INSERT INTO molecules (canonical_smiles, mol)
SELECT DISTINCT ON (canon) canon, mol
FROM bbbp_parsed WHERE mol IS NOT NULL
ORDER BY canon
ON CONFLICT (canonical_smiles) DO NOTHING;

INSERT INTO dataset_records (dataset, row_idx, mol_id, raw_smiles, label)
SELECT 'bbbp', p.row_idx, m.mol_id, p.smiles, p.label
FROM bbbp_parsed p
JOIN molecules m ON m.canonical_smiles = p.canon;

-- Reconcile BEFORE committing: staged must equal loaded + rejected
SELECT (SELECT count(*) FROM bbbp_stage)                                AS staged,
       (SELECT count(*) FROM dataset_records WHERE dataset = 'bbbp')    AS loaded,
       (SELECT count(*) FROM ingest_rejects  WHERE dataset = 'bbbp')    AS rejected,
       (SELECT count(*) FROM molecules)                                 AS distinct_molecules;

COMMIT;   -- or ROLLBACK if the numbers don't add up