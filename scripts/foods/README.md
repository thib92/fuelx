# Food data import

Builds the `foods` table from CIQUAL and Open Food Facts (OFF). The rules are in
`docs/superpowers/specs/2026-11-05-meal-logging-design.md`.

Everything runs by hand from the repo root. Downloads go in `scripts/foods/data/`, which is
git-ignored. You need the `duckdb` CLI.

## 1. Download

- **OFF:** `https://huggingface.co/datasets/openfoodfacts/product-database/resolve/main/food.parquet?download=true`,
  saved as `scripts/foods/data/food.parquet` (8 GB).
- **CIQUAL:** the `alim_*.xml` and `compo_*.xml` files from dataset
  [`doi:10.57745/RDMHWY`](https://doi.org/10.57745/RDMHWY), saved as
  `scripts/foods/data/ciqual/alim.xml` and `compo.xml`. Newer releases may have a different DOI.

## 2. Build

```sh
duckdb < scripts/foods/extract-off.sql
npx tsx scripts/foods/build.ts
```

This writes `scripts/foods/data/foods.jsonl` and prints how many foods were kept. Expect about
620,000 OFF foods and at least 3,323 CIQUAL foods; investigate a large change before uploading.

## 3. Upload

Choose a long random value for `FOODS_IMPORT_SECRET`, then set it on the deployment and in your
shell:

```sh
npx convex env set FOODS_IMPORT_SECRET "$FOODS_IMPORT_SECRET"
npx tsx scripts/foods/upload.ts
```

Store the secret without a trailing newline: `npx convex env set --from-file` keeps it, and the
upload is then rejected with "Not allowed".

Upload targets `CONVEX_URL` from `.env.local`, so change that to reach production. The first run
takes about 50 minutes. If it fails, it prints a line number; pass that to resume.

## Refreshing

Repeat all three steps, for example once a quarter. Unchanged foods are skipped, and `label` and
`custom` foods are never touched. Log entries keep their own copy of nutrition values, so history
doesn't change. Foods that disappear from a source stay in the table, because log history and
recents may point to them.

OFF's daily deltas aren't used: they only cover 14 days and can't report deletions.

## Attribution

OFF data is under the Open Database License, and CIQUAL under Licence Ouverte (Etalab 2.0). Both
are credited on the app's About screen.
