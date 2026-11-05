import { checkFood, expectedKcal, kcalFromKj, type Per100g } from "../../convex/lib/foodQuality";
import { searchTextFor } from "../../convex/lib/foodSearch";
import type { ImportDoc } from "../../convex/schema";

const MAX_SERVING_G = 5000;

/** CIQUAL constituent codes for the nutrients we keep. */
const CIQUAL_NUTRIENTS: Record<string, keyof Per100g> = {
  "328": "kcal",
  "25000": "proteinG",
  "31000": "carbsG",
  "40000": "fatG",
  "32000": "sugarG",
  "34100": "fiberG",
  "10004": "saltG",
};

/** One line of the extract written by extract-off.sql. */
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
  serving_quantity: string | null;
  unique_scans_n: number | null;
};

function round(value: number, decimals: number): number {
  const factor = 10 ** decimals;
  return Math.round(value * factor) / factor;
}

/** Rounds to what we store, leaving out nutrients the source doesn't have. */
function roundPer100g(values: Per100g): Per100g {
  const optional = (key: "sugarG" | "fiberG" | "saltG", decimals: number) =>
    values[key] === undefined ? {} : { [key]: round(values[key], decimals) };
  return {
    kcal: round(values.kcal, 0),
    proteinG: round(values.proteinG, 1),
    carbsG: round(values.carbsG, 1),
    fatG: round(values.fatG, 1),
    ...optional("sugarG", 1),
    ...optional("fiberG", 1),
    ...optional("saltG", 2),
  };
}

/** CIQUAL writes `12,3`, `traces`, `< 0,5` (kept as the bound) and `-` for missing. */
export function parseCiqualValue(raw: string): number | undefined {
  const text = raw.trim().replace(",", ".");
  if (text.toLowerCase() === "traces") return 0;
  const number = text.replace(/^<\s*/, "");
  if (number === "" || !/^\d+(\.\d+)?$/.test(number)) return undefined;
  return Number(number);
}

function decodeXml(text: string): string {
  return text
    .replace(/&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function tagText(element: string, tag: string): string | undefined {
  const match = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(element);
  return match ? decodeXml(match[1]).trim() : undefined;
}

/** Reads CIQUAL's alim file. */
export function parseCiqualFoods(xml: string) {
  const foods: { code: string; nameFr: string; nameEn: string }[] = [];
  for (const [element] of xml.matchAll(/<ALIM>[\s\S]*?<\/ALIM>/g)) {
    const code = tagText(element, "alim_code");
    const nameFr = tagText(element, "alim_nom_fr");
    if (code && nameFr) {
      foods.push({ code, nameFr, nameEn: tagText(element, "alim_nom_eng") ?? "" });
    }
  }
  return foods;
}

/** Reads CIQUAL's compo file into each food's tracked nutrients. */
export function parseCiqualValues(xml: string): Map<string, Partial<Per100g>> {
  const values = new Map<string, Partial<Per100g>>();
  for (const [element] of xml.matchAll(/<COMPO>[\s\S]*?<\/COMPO>/g)) {
    const code = tagText(element, "alim_code");
    const nutrient = CIQUAL_NUTRIENTS[tagText(element, "const_code") ?? ""];
    const value = parseCiqualValue(tagText(element, "teneur") ?? "");
    if (!code || !nutrient || value === undefined) continue;
    values.set(code, { ...values.get(code), [nutrient]: value });
  }
  return values;
}

/** A CIQUAL food, or null without complete macros. */
export function ciqualFood(
  code: string,
  nameFr: string,
  nameEn: string,
  values: Partial<Per100g>,
): ImportDoc | null {
  const { proteinG, carbsG, fatG, kcal } = values;
  if (proteinG === undefined || carbsG === undefined || fatG === undefined) return null;
  const complete = { ...values, proteinG, carbsG, fatG, kcal: kcal ?? 0 };
  return {
    source: "ciqual",
    sourceId: code,
    name: nameFr,
    nameEn,
    searchText: searchTextFor({ name: nameFr, nameEn }),
    per100g: roundPer100g({ ...complete, kcal: kcal ?? expectedKcal(complete) }),
  };
}

/** An OFF product, or null if it fails the import rules (spec rules 2-7). */
export function offFood(row: OffRow): ImportDoc | null {
  const name = (row.name_fr?.trim() || row.name_main?.trim()) ?? "";
  const brand = row.brands?.split(",")[0].trim() || undefined;
  const offScans = row.unique_scans_n || undefined;
  if (!brand && !offScans) return null;

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
