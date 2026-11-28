\set ON_ERROR_STOP on
\set query_smiles 'CC(=O)Oc1ccccc1C(=O)O'
\set similarity_threshold '0.3'

BEGIN;
SELECT set_config('rdkit.tanimoto_threshold', :'similarity_threshold', true);

WITH query_fingerprint AS (
    SELECT morganbv_fp(mol_from_smiles(:'query_smiles'::cstring)) AS fingerprint
)
SELECT m.mol_id,
       m.canonical_smiles,
       tanimoto_sml(m.fingerprint, q.fingerprint) AS tanimoto_similarity
FROM molecules AS m
CROSS JOIN query_fingerprint AS q
WHERE m.fingerprint % q.fingerprint
ORDER BY tanimoto_similarity DESC, m.mol_id
LIMIT 10;
COMMIT;
