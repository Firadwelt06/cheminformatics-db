\set ON_ERROR_STOP on

SELECT count(*)
FROM molecules
WHERE mol @> 'c1ccccc1'::qmol;
