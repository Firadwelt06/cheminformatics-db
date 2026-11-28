\set ON_ERROR_STOP on

INSERT INTO bench.query_catalog (query_id, description, smarts)
VALUES
    (
        'Q1',
        'Rare boron atom; one BBBP match.',
        '[B]'
    ),
    (
        'Q2',
        'Moderately rare sulfonamide.',
        'S(=O)(=O)N'
    ),
    (
        'Q3',
        'Common benzene ring.',
        'c1ccccc1'
    ),
    (
        'Q4',
        'Common carboxylic acid.',
        'C(=O)[OH]'
    ),
    (
        'Q5',
        'Carbon atom; matches essentially every molecule.',
        '[#6]'
    ),
    (
        'Q6',
        'Selenium atom; no BBBP molecules match.',
        '[Se]'
    ),
    (
        'Q7',
        'Selenium-carbon bond; tests whether carbon lowers Q6 signature collisions.',
        '[Se]C'
    ),
    (
        'Q8',
        'Carbon-selenium-carbon pattern; tests whether a second carbon lowers Q6 signature collisions.',
        'C[Se]C'
    )
ON CONFLICT (query_id) DO UPDATE
SET description = EXCLUDED.description,
    smarts = EXCLUDED.smarts;
