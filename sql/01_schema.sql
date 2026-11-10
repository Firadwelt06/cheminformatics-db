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
CREATE INDEX dataset_records_mol_id_idx ON dataset_records (mol_id); -- Postgres doesn't index FKs for you

CREATE TABLE ingest_rejects (
    dataset       text        NOT NULL,
    row_idx       integer     NOT NULL,
    raw_smiles    text,
    label         smallint,
    reject_reason text        NOT NULL,
    rejected_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dataset, row_idx)
);
