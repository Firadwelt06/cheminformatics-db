CREATE EXTENSION IF NOT EXISTS rdkit;

-- A dataset identifies one source artifact and the conditions used to load it.
CREATE TABLE datasets (
    dataset     text        PRIMARY KEY,
    source_url  text,
    citation    text,
    license     text        NOT NULL DEFAULT 'unknown',
    version     text,
    file_sha256 text        CHECK (file_sha256 IS NULL OR file_sha256 ~ '^[0-9a-f]{64}$'),
    loaded_at   timestamptz NOT NULL DEFAULT now()
);

-- One row per distinct molecule (immutable, expensive columns)
CREATE TABLE molecules (
    mol_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canonical_smiles text NOT NULL,
    mol              mol  NOT NULL,
    CONSTRAINT molecules_canonical_smiles_key UNIQUE (canonical_smiles)
);

-- One row per dataset record (cheap, mutable annotations)
CREATE TABLE dataset_records (
    dataset    text     NOT NULL REFERENCES datasets (dataset),
    row_idx    integer  NOT NULL,
    mol_id     bigint   NOT NULL REFERENCES molecules (mol_id),
    raw_smiles text     NOT NULL,
    label      smallint NOT NULL,
    PRIMARY KEY (dataset, row_idx)
);
CREATE INDEX dataset_records_mol_id_idx ON dataset_records (mol_id); -- Postgres doesn't index FKs for you

CREATE TABLE ingest_rejects (
    dataset       text        NOT NULL REFERENCES datasets (dataset),
    row_idx       integer     NOT NULL,
    raw_smiles    text,
    label         smallint,
    reject_reason text        NOT NULL,
    rejected_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dataset, row_idx)
);

-- Compute optional identity metadata only when requested, not on every stored row.
CREATE VIEW v_molecule_identity AS
SELECT mol_id,
       canonical_smiles,
       mol_formula(mol)::text AS molecular_formula,
       mol_amw(mol)     AS molecular_weight
FROM molecules;

CREATE VIEW v_molecule_fingerprints AS
SELECT mol_id, morganbv_fp(mol) AS fingerprint
FROM molecules;

CREATE VIEW v_label_balance AS
SELECT dataset,
       label,
       count(*) AS record_count,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY dataset), 2) AS percent_of_dataset
FROM dataset_records
GROUP BY dataset, label;

CREATE VIEW v_duplicate_groups AS
SELECT dataset,
       mol_id,
       count(*) AS n_records,
       count(DISTINCT label) AS n_labels,
       array_agg(row_idx ORDER BY row_idx) AS row_idxs
FROM dataset_records
GROUP BY dataset, mol_id
HAVING count(*) > 1;

CREATE VIEW v_label_conflicts AS
SELECT dataset,
       mol_id,
       count(*) AS n_records,
       count(DISTINCT label) AS n_labels,
       array_agg(row_idx ORDER BY row_idx) AS row_idxs
FROM dataset_records
GROUP BY dataset, mol_id
HAVING count(DISTINCT label) > 1;

CREATE VIEW v_load_summary AS
SELECT d.dataset,
       d.source_url,
       d.citation,
       d.license,
       d.version,
       d.file_sha256,
       d.loaded_at,
       coalesce(r.loaded_records, 0) AS loaded_records,
       coalesce(r.distinct_molecules, 0) AS distinct_molecules,
       coalesce(i.rejected_records, 0) AS rejected_records
FROM datasets d
LEFT JOIN (
    SELECT dataset, count(*) AS loaded_records, count(DISTINCT mol_id) AS distinct_molecules
    FROM dataset_records
    GROUP BY dataset
) r USING (dataset)
LEFT JOIN (
    SELECT dataset, count(*) AS rejected_records
    FROM ingest_rejects
    GROUP BY dataset
) i USING (dataset);
