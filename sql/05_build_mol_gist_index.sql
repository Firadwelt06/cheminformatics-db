\set ON_ERROR_STOP on

CREATE INDEX IF NOT EXISTS molecules_mol_gist
    ON molecules USING gist (mol);
