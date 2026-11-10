# cheminformatics-db

A relational database engine and data model for cheminformatics workflows.

This repository is the first in a 3-part series of "proofs of genius" projects. The intent is to build a chemistry-aware relational foundation that can support scientific data capture, queryability, provenance, and experimentation without forcing all workflows into a single monolithic schema.

## Project goal

Build a robust, queryable, chemistry-aware database layer for:
- molecular structures
- assay metadata
- reaction and dataset provenance
- compound identity and registration
- searchable structure and similarity features
- reproducible ingestion pipelines

## Current status

The repository already includes:
- Dockerized PostgreSQL + RDKit setup
- a molecule ingestion schema
- an initial SQL pattern for loading parsed SMILES into a relational table
- a reject table for invalid or non-parseable molecules

## Architecture direction

This repo is structured around a PostgreSQL foundation with RDKit extension support:

- `docker/` — database container setup
- `sql/` — schema and loading scripts
- `data/` — ingestion and datasets
- `docs/` — project governance, journal, roadmap

## Quick start

```bash
docker compose up --build
```

Then connect to PostgreSQL on port 5432 using:
- user: `chem`
- password: `chem_dev_pw`
- database: `chemdb`

## Milestones

1. M0 — Definition and constraints
2. M1 — Schema foundation and ingestion pipeline
3. M2 — Chemistry-aware search and analytics
4. M3 — API and reproducibility layer
5. M4 — Benchmarking and validation

See `docs/roadmap.md` for the full project plan.

## Working rhythm

This project should be run like a technical research program, not just a repo.

- maintain a project brief
- keep a weekly journal
- write decisions and tradeoffs explicitly
- track assumptions, failed experiments, and next actions

## Journal workflow

Use the template in `docs/journal-template.md` for every weekly update.

Each entry should cover:
- objective
- decisions made
- evidence collected
- open risks
- next action

## Issue workflow

Use the issue templates in `.github/ISSUE_TEMPLATE/` for:
- feature work
- research tasks
- schema/design changes
- data ingestion problems
- benchmark and validation tasks

## Recommended next tasks

The repo is ready for the next stage:
- formalize the chemical schema
- define source tables for training and assay data
- create validation queries
- add ingestion smoke tests
- capture reproducibility notes in the journal

## License

This repository is intentionally kept lightweight and open for rapid iteration.
