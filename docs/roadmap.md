# Project roadmap

## Milestone 0 — Definition and constraints

Goal: define what the relational engine will store and what it will not.

Outcomes:
- confirm the canonical entities (molecule, compound, assay, dataset, provenance)
- define required chemistry fields (SMILES, InChI, standardization, stereochemistry)
- document assumptions, constraints, and accepted data sources
- capture data quality requirements

## Milestone 1 — Core schema foundation

Goal: create a stable relational model suitable for ingesting chemistry and assay data.

Outcomes:
- molecule table
- compound table
- dataset table
- provenance table
- ingestion reject table
- migration-friendly SQL structure

## Milestone 2 — Chemistry-aware ingestion and indexing

Goal: make the engine capable of handling real molecular data safely and repeatably.

Outcomes:
- parse SMILES with RDKit
- validate malformed entries
- track bad rows explicitly
- add index patterns for search and filtering
- support dataset versioning

## Milestone 3 — Query and retrieval engine

Goal: expose the engine for real use and experimentation.

Outcomes:
- SQL query patterns
- structure filtering patterns
- compound lookup by identity or fingerprint
- retrieval from dataset tables
- benchmarkable queries

## Milestone 4 — Validation and benchmarking

Goal: prove the system is reliable enough for use in experimentation.

Outcomes:
- schema validation tests
- ingestion quality metrics
- query performance baselines
- release criteria
- reproducibility notes

## Notes for this repo

This repository already contains the base infrastructure for Milestone 1 and the beginning of Milestone 2. The next work should focus on turning the current SQL prototype into a properly governed and documented data platform.
