\set ON_ERROR_STOP on

INSERT INTO bench.query_catalog (query_id, description, sql_text)
VALUES
    (
        'Q1',
        'Rare boron atom; selenium matched no BBBP rows.',
        'SELECT mol_id FROM molecules WHERE mol @> ''[B]''::qmol;'
    ),
    (
        'Q2',
        'Moderately rare sulfonamide.',
        'SELECT mol_id FROM molecules WHERE mol @> ''S(=O)(=O)N''::qmol;'
    ),
    (
        'Q3',
        'Common benzene ring.',
        'SELECT mol_id FROM molecules WHERE mol @> ''c1ccccc1''::qmol;'
    ),
    (
        'Q4',
        'Common carboxylic acid.',
        'SELECT mol_id FROM molecules WHERE mol @> ''C(=O)[OH]''::qmol;'
    ),
    (
        'Q5',
        'Carbon atom; matches essentially every molecule.',
        'SELECT mol_id FROM molecules WHERE mol @> ''[#6]''::qmol;'
    )
ON CONFLICT (query_id) DO UPDATE
SET description = EXCLUDED.description,
    sql_text = EXCLUDED.sql_text;
