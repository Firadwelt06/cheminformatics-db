\set ON_ERROR_STOP on

BEGIN;
SET LOCAL client_min_messages = error;

CREATE TEMP TABLE bbbp_parsed ON COMMIT DROP AS
SELECT row_idx, smiles, label, mol,
       CASE WHEN mol IS NOT NULL THEN mol_numatoms(mol) END        AS n_atoms,
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
ORDER BY canon, row_idx          -- row_idx makes the surviving duplicate deterministic
ON CONFLICT (canonical_smiles) DO NOTHING;

INSERT INTO dataset_records (dataset, row_idx, mol_id, raw_smiles, label)
SELECT 'bbbp', p.row_idx, m.mol_id, p.smiles, p.label
FROM bbbp_parsed p
JOIN molecules m ON m.canonical_smiles = p.canon
WHERE p.n_atoms > 0
ON CONFLICT (dataset, row_idx) DO NOTHING;

-- Assert instead of eyeballing: abort and roll back if the books don't balance
DO $$
DECLARE staged int; loaded int; rejected int;
BEGIN
    SELECT count(*) INTO staged   FROM bbbp_stage;
    SELECT count(*) INTO loaded   FROM dataset_records WHERE dataset = 'bbbp';
    SELECT count(*) INTO rejected FROM ingest_rejects  WHERE dataset = 'bbbp';
    IF staged <> loaded + rejected THEN
        RAISE EXCEPTION 'reconciliation failed: staged=% loaded=% rejected=%',
                        staged, loaded, rejected;
    END IF;
END $$;

COMMIT;

ANALYZE molecules;
ANALYZE dataset_records;

SELECT (SELECT count(*) FROM bbbp_stage)                             AS staged,
       (SELECT count(*) FROM dataset_records WHERE dataset = 'bbbp') AS loaded,
       (SELECT count(*) FROM ingest_rejects  WHERE dataset = 'bbbp') AS rejected,
       (SELECT count(*) FROM molecules)                              AS distinct_molecules;