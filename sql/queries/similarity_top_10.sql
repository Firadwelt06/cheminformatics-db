\set ON_ERROR_STOP on
\set query_smiles 'CC(=O)Oc1ccccc1C(=O)O'

WITH query_fingerprint AS (
    SELECT morganbv_fp(mol_from_smiles(:'query_smiles'::cstring)) AS fingerprint
)
SELECT m.mol_id,
       m.canonical_smiles,
       tanimoto_sml(fp.fingerprint, q.fingerprint) AS tanimoto_similarity
FROM molecules m
JOIN v_molecule_fingerprints fp USING (mol_id)
CROSS JOIN query_fingerprint q
ORDER BY tanimoto_similarity DESC, m.mol_id
LIMIT 10;
