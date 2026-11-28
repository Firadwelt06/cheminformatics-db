\set ON_ERROR_STOP on

ALTER TABLE molecules
    ADD COLUMN IF NOT EXISTS fingerprint bfp;

UPDATE molecules
SET fingerprint = morganbv_fp(mol)
WHERE fingerprint IS NULL;

ALTER TABLE molecules
    ALTER COLUMN fingerprint SET NOT NULL;

CREATE INDEX IF NOT EXISTS molecules_fingerprint_gist
    ON molecules USING gist (fingerprint gist_bfp_ops);

CREATE OR REPLACE VIEW v_molecule_fingerprints AS
SELECT mol_id, fingerprint
FROM molecules;
