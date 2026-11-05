-- Extracts France products from Open Food Facts' Parquet export into JSONL for build.ts.
-- Only rule 1 runs here; every other rule is applied in TypeScript.
-- Run from the repo root: duckdb < scripts/foods/extract-off.sql

-- OFF has some Infinity and NaN values, which JSON can't represent, so they become null.
CREATE MACRO finite(value) AS CASE WHEN isfinite(value) THEN value END;
CREATE MACRO nutrient(list, key) AS finite(list_filter(list, lambda x: x.name = key)[1]."100g");
CREATE MACRO localized(list, key) AS list_filter(list, lambda x: x.lang = key AND trim(x.text) <> '')[1].text;

COPY (
  SELECT
    code,
    localized(product_name, 'fr') AS name_fr,
    localized(product_name, 'main') AS name_main,
    brands,
    nutrient(nutriments, 'energy-kcal') AS kcal,
    coalesce(nutrient(nutriments, 'energy-kj'), nutrient(nutriments, 'energy')) AS kj,
    nutrient(nutriments, 'proteins') AS proteins,
    nutrient(nutriments, 'carbohydrates') AS carbohydrates,
    nutrient(nutriments, 'fat') AS fat,
    nutrient(nutriments, 'sugars') AS sugars,
    nutrient(nutriments, 'fiber') AS fiber,
    nutrient(nutriments, 'salt') AS salt,
    nutrient(nutriments, 'alcohol') AS alcohol,
    serving_quantity,
    unique_scans_n
  FROM read_parquet('scripts/foods/data/food.parquet')
  WHERE list_contains(countries_tags, 'en:france') AND obsolete IS NOT TRUE
) TO 'scripts/foods/data/off-france.jsonl' (FORMAT JSON);
