import type { ImportDoc } from "../schema";
import { checkFood, kcalFromKj, round, roundPer100g, type Per100g } from "./foodQuality";
import { searchTextFor } from "./foodSearch";

const MAX_SERVING_G = 5000;
const OFF_API_URL = "https://world.openfoodfacts.org/api/v2/product";
const OFF_FIELDS = "product_name,product_name_fr,brands,nutriments,serving_quantity,unique_scans_n";
const OFF_TIMEOUT_MS = 8000;

/** An OFF product: one line of the extract from extract-off.sql, or a live API response. */
export type OffRow = {
  code: string;
  name_fr: string | null;
  name_main: string | null;
  brands: string | null;
  kcal: number | null;
  kj: number | null;
  proteins: number | null;
  carbohydrates: number | null;
  fat: number | null;
  sugars: number | null;
  fiber: number | null;
  salt: number | null;
  alcohol: number | null;
  serving_quantity: string | number | null;
  unique_scans_n: number | null;
};

/** The fields we request from OFF's product API. */
export type OffApiProduct = {
  product_name?: string | null;
  product_name_fr?: string | null;
  brands?: string | null;
  nutriments?: Record<string, unknown> | null;
  serving_quantity?: string | number | null;
  unique_scans_n?: number | null;
};

export type OffLookup = OffRow | "notFound" | "unavailable";

/** A food from an OFF product, or null if it fails rules 2-6. */
export function offDoc(row: OffRow): ImportDoc | null {
  const name = (row.name_fr?.trim() || row.name_main?.trim()) ?? "";
  const brand = row.brands?.split(",")[0].trim() || undefined;
  const offScans = row.unique_scans_n || undefined;

  const kcal = row.kcal ?? (row.kj === null ? null : kcalFromKj(row.kj));
  if (kcal === null || row.proteins === null || row.carbohydrates === null || row.fat === null) {
    return null;
  }
  const per100g: Per100g = {
    kcal,
    proteinG: row.proteins,
    carbsG: row.carbohydrates,
    fatG: row.fat,
    ...(row.sugars !== null && { sugarG: row.sugars }),
    ...(row.fiber !== null && { fiberG: row.fiber }),
    ...(row.salt !== null && { saltG: row.salt }),
  };
  const check = checkFood({
    barcode: row.code,
    name,
    per100g,
    alcoholPct: row.alcohol ?? undefined,
  });
  if (!check.ok) return null;

  const servingG = Number(row.serving_quantity);
  return {
    source: "off",
    sourceId: row.code,
    barcode: row.code,
    name,
    ...(brand && { brand }),
    searchText: searchTextFor({ name, brand }),
    per100g: roundPer100g(per100g),
    ...(servingG > 0 && servingG <= MAX_SERVING_G && { servingG: round(servingG, 1) }),
    ...(offScans && { offScans }),
  };
}

/** OFF sometimes sends numbers as strings. */
function numberOrNull(value: unknown): number | null {
  const number = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) ? number : null;
}

/** Keeps the scanned barcode, so the next scan of it finds the saved food. */
export function offRowFromApi(barcode: string, product: OffApiProduct): OffRow {
  const nutrient = (name: string) => numberOrNull(product.nutriments?.[`${name}_100g`]);
  return {
    code: barcode,
    name_fr: product.product_name_fr ?? null,
    name_main: product.product_name ?? null,
    brands: product.brands ?? null,
    kcal: nutrient("energy-kcal"),
    // `energy_100g` is always in kJ.
    kj: nutrient("energy-kj") ?? nutrient("energy"),
    proteins: nutrient("proteins"),
    carbohydrates: nutrient("carbohydrates"),
    fat: nutrient("fat"),
    sugars: nutrient("sugars"),
    fiber: nutrient("fiber"),
    salt: nutrient("salt"),
    alcohol: nutrient("alcohol"),
    serving_quantity: product.serving_quantity ?? null,
    unique_scans_n: product.unique_scans_n ?? null,
  };
}

/** Asks OFF for a product. OFF answers 404 for a product it doesn't have. */
export async function fetchOffRow(barcode: string, userAgent: string): Promise<OffLookup> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), OFF_TIMEOUT_MS);
  try {
    const response = await fetch(`${OFF_API_URL}/${barcode}.json?fields=${OFF_FIELDS}`, {
      headers: { "User-Agent": userAgent },
      signal: controller.signal,
    });
    if (response.status === 404) return "notFound";
    if (!response.ok) {
      console.error(`OFF lookup failed with status ${response.status}`);
      return "unavailable";
    }
    const { product } = (await response.json()) as { product?: OffApiProduct | null };
    return product ? offRowFromApi(barcode, product) : "notFound";
  } catch (error) {
    console.error("OFF lookup failed", error);
    return "unavailable";
  } finally {
    clearTimeout(timeout);
  }
}
