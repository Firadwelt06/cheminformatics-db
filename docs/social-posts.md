# Social post drafts

## LinkedIn carousel

**Suggested image:** [Annotated PostgreSQL plan](./substructure-plan.png)

**Carousel/caption copy:**

PostgreSQL estimated 2 matching molecules. The real answer was 1,367.

SMILES parsed per row: ~0.30–0.35 ms/row. Stored RDKit `mol`: ~0.06 ms/row.

That speed costs ~6.9× more storage: 357 B vs 52 B per value.

And 10 duplicate groups had conflicting BBBP labels—even after structure canonicalization.

Chemistry knowledge told me what might be hiding in the data. The query plan showed how badly the planner guessed.

Repo: https://github.com/Firadwelt06/cheminformatics-db  
Week 2: indexes and 10M rows.

## YouTube Shorts scripts

### Short 1 — The planner guessed two

**[Show the plan screenshot. Point to “rows=2,” then “actual rows=1367.”]**

“PostgreSQL thought this query would return two molecules. It returned 1,367.

I searched for a benzene ring inside stored molecules using RDKit in PostgreSQL. The planner used a generic selectivity guess—it doesn't know benzene rings are common in this dataset.

This is a small, unindexed, 2,000-row benchmark, not a production claim. But it's a great reminder: always compare estimated rows with actual rows.

Week 2: indexes, parallel workers, and 10 million rows.”

### Short 2 — A valid string, zero atoms

**[Show a text card: `SMILES = ''` → valid molecule → 0 atoms.]**

“Here's a weird data-quality trap: RDKit can parse an empty SMILES string as a valid molecule—with zero atoms.

So checking only ‘did parsing return something?’ isn't enough. My loader checks atom count too, and sends empty structures to a reject table instead of quietly storing junk.

The current dataset had zero rejects. The guard is there for the next dataset that isn't so clean.”

### Short 3 — Same molecule, different labels

**[Show the aspirin pair from the SQL output, side by side with labels 0 and 1.]**

“These two SMILES strings look different, but they describe aspirin in different atom traversals. After canonicalization they point to the same molecule—and the dataset gives one record label zero and the other label one.

My hypothesis is source or measurement label noise. Salt forms, charge, and stereochemistry are possibilities to investigate in other cases, but I can't claim those caused this pair without tracing the source records.

Chemistry helps ask the right question. It doesn't replace provenance.”
