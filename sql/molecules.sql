CREATE EXTENSION IF NOT EXISTS rdkit;

-- One row per distinct molecule (immutable, expensive columns)
CREATE TABLE IF NOT EXISTS molecules (
    mol_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canonical_smiles text NOT NULL,
    mol              mol  NOT NULL,
    CONSTRAINT molecules_canonical_smiles_key UNIQUE (canonical_smiles)
);

-- One row per dataset record (cheap, mutable annotations)
CREATE TABLE IF NOT EXISTS dataset_records (
    dataset    text     NOT NULL,
    row_idx    integer  NOT NULL,
    mol_id     bigint   NOT NULL REFERENCES molecules (mol_id),
    raw_smiles text     NOT NULL,
    label      smallint NOT NULL,
    PRIMARY KEY (dataset, row_idx)
);
CREATE INDEX IF NOT EXISTS dataset_records_mol_id_idx ON dataset_records (mol_id);

-- One row per rejected input record
CREATE TABLE IF NOT EXISTS ingest_rejects (
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
SELECT row_idx,
       smiles,
       label,
       mol,
       CASE WHEN mol IS NOT NULL THEN mol_numatoms(mol) END AS n_atoms,
       CASE WHEN mol IS NOT NULL THEN mol_to_smiles(mol)::text END AS canon
FROM (
    SELECT row_idx, smiles, label, mol_from_smiles(smiles::cstring) AS mol
    FROM bbbp_stage
) s;

INSERT INTO ingest_rejects (dataset, row_idx, raw_smiles, label, reject_reason)
SELECT 'bbbp', row_idx, smiles, label,
       CASE WHEN mol IS NULL THEN 'parse_failed' ELSE 'empty_molecule' END
FROM bbbp_parsed
WHERE mol IS NULL OR n_atoms = 0
ON CONFLICT (dataset, row_idx) DO NOTHING;

INSERT INTO molecules (canonical_smiles, mol)
SELECT DISTINCT ON (canon) canon, mol
FROM bbbp_parsed
WHERE mol IS NOT NULL AND n_atoms > 0
ORDER BY canon
ON CONFLICT (canonical_smiles) DO NOTHING;

INSERT INTO dataset_records (dataset, row_idx, mol_id, raw_smiles, label)
SELECT 'bbbp', p.row_idx, m.mol_id, p.smiles, p.label
FROM bbbp_parsed p
JOIN molecules m ON m.canonical_smiles = p.canon
WHERE p.n_atoms > 0
ON CONFLICT (dataset, row_idx) DO NOTHING;

-- Reconcile: staged must equal loaded + rejected
SELECT (SELECT count(*) FROM bbbp_stage) AS staged,
       (SELECT count(*) FROM dataset_records WHERE dataset = 'bbbp') AS loaded,
       (SELECT count(*) FROM ingest_rejects WHERE dataset = 'bbbp') AS rejected,
       (SELECT count(*) FROM molecules) AS distinct_molecules;

COMMIT;

ANALYZE molecules;

-- The duplicate analysis
WITH g AS (
    SELECT mol_id, count(*) AS n, count(DISTINCT label) AS n_labels
    FROM dataset_records
    WHERE dataset = 'bbbp'
    GROUP BY mol_id
    HAVING count(*) > 1
)
SELECT count(*)                                  AS dup_groups,
       max(n)                                    AS largest_group,
       count(*) FILTER (WHERE n_labels > 1)      AS conflicting_label_groups
FROM g;