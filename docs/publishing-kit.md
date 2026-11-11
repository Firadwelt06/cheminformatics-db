# Publishing kit

## What goes where

| Asset | Use |
|---|---|
| [Blog draft](./blog-post.md) | Publish as a blog article. Keep the annotated plan near the opening and the duplicate query in a code block. |
| [Annotated plan](./substructure-plan.png) | Blog hero, LinkedIn cover, or a cutaway in Short 1. |
| [Schema diagram](./schema-diagram.png) | Blog architecture section, README, and LinkedIn slide 3. |
| [Label-conflict evidence](./evidence-duplicate-labels.png) | Blog duplicate section, LinkedIn slide 4, and Short 3. |
| [Empty-SMILES evidence](./evidence-empty-smiles.png) | Blog empty-string section and Short 2. |
| [LinkedIn slides](./linkedin-slide-01.png)–[05](./linkedin-slide-05.png) | Upload as one five-page document/carousel, in numerical order. |
| [LinkedIn carousel PDF](./linkedin-carousel.pdf) | Ready-to-upload five-page carousel document. |
| [Short 1 visual](./short-01-planner.png), [Short 2 visual](./short-02-empty-smiles.png), [Short 3 visual](./short-03-label-conflict.png) | Vertical 9:16 graphics to layer with your recorded footage. |
| [Social copy and Shorts scripts](./social-posts.md) | Caption and three separate YouTube Shorts voiceover scripts. |

These are designed graphics using measurements and query results checked against the local PostgreSQL/RDKit run. They are intentionally not presented as unedited terminal screenshots. Use the actual query output, not the artwork alone, as reproducibility evidence.

## Blog publishing

1. Paste [blog-post.md](./blog-post.md) into your publishing platform's editor and preview the Markdown formatting (especially the SQL code block).
2. Upload `substructure-plan.png` and place it immediately below the title/lede. Upload `evidence-duplicate-labels.png` with the duplicate section and `schema-diagram.png` in the architecture section. The empty-SMILES image is optional if the editor starts to feel image-heavy.
3. Use meaningful alt text, such as “PostgreSQL estimated 2 rows for a benzene substructure query; EXPLAIN ANALYZE returned 1,367.”
4. Preview on desktop and mobile. Keep the limitation paragraph and primary-source qualification intact; don't crop away the “single machine / no index” context.
5. Add a short author bio and publish date in the platform's fields. The repository link is already in the draft.

## LinkedIn carousel setup

1. Start a LinkedIn post and choose **Add a document** (not a single-image post).
2. Upload [linkedin-carousel.pdf](./linkedin-carousel.pdf). It has five portrait 4:5 pages (1080 × 1350 source slides) in the intended order. The individual numbered PNGs are there if you need to revise or re-export a slide.
3. Use the caption from [social-posts.md](./social-posts.md). Add a short document title such as “When PostgreSQL estimated 2 rows—and 1,367 matched.”
4. Preview page order and legibility in the LinkedIn composer, then add a concise alt-text/description if the upload flow offers it.
5. The plan image is the opening visual. The remaining slides explain storage, schema, conflicting labels, and the 10M-row next step.

## YouTube Shorts setup

Yes: publish **three distinct Shorts**, not one video with three unrelated sections. Each has one hook, one visual idea, and its own script in [social-posts.md](./social-posts.md).

1. Record vertically (9:16) at 1080 × 1920 or higher, with the phone/camera upright and the lens near eye level. Use a quiet room, front lighting, and an external mic or close phone mic if available.
2. Record each script as a separate take. Leave a beat after the opening line, keep the on-screen graphic visible long enough to read, and aim for roughly 20–35 seconds. Trim dead air; use captions because many people watch muted.
3. Use `short-01-planner.png`, `short-02-empty-smiles.png`, or `short-03-label-conflict.png` as the matching vertical cutaway/background. These are 9:16 title/evidence cards, not substitutes for footage. Add a screen recording or face-to-camera footage in your editor if desired.
4. Export each separately as 1080 × 1920 MP4, H.264 video + AAC audio, with no black bars. Preview the first and last seconds and confirm the numbers/text remain inside the mobile-safe area.
5. In YouTube Studio, upload each as its own video, add a distinct title/description, set audience and visibility, and check the preview before publishing. Use the repo link in each description. Platform upload requirements can change; follow the current Studio prompts.

Suggested titles:

- **Short 1:** PostgreSQL guessed 2 rows. 1,367 matched.
- **Short 2:** The empty SMILES string that parses as a molecule.
- **Short 3:** Same molecule, different labels: a chemistry data mystery.

## Schema diagram: how to read it

`molecules` stores the parsed structure once per canonical SMILES. Each `dataset_records` row retains the dataset, original row number, original SMILES, and label, and points to one molecule through `mol_id`; multiple source rows can therefore refer to one molecule. `ingest_rejects` retains failed or zero-atom input rows and their reason; it has no foreign-key relationship to `molecules` because rejected input may have no valid structure to reference.

The diagram mirrors the current SQL: composite primary keys are shown on `dataset_records` and `ingest_rejects`, `canonical_smiles` is unique, and the only relationship line is the actual `dataset_records.mol_id` foreign key. It deliberately does not imply a dataset registry or a molecule foreign key for rejects.
