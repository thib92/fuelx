/**
 * Quality rules for food data, shared by the bulk import and live lookups.
 * See "Food data" in docs/superpowers/specs/2026-11-05-meal-logging-design.md.
 */

export type Per100g = {
  kcal: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  sugarG?: number;
  fiberG?: number;
  saltG?: number;
};

export type FoodCandidate = {
  barcode: string;
  name: string;
  per100g: Per100g;
  alcoholPct?: number;
};

export type FoodCheck =
  | { ok: true }
  | { ok: false; rule: "barcode" | "name" | "range" | "calories" };

const BARCODE_PATTERN = /^(\d{8}|\d{12,14})$/;
const MIN_NAME_LENGTH = 3;
const MAX_KCAL = 950;
const MAX_MACRO_G = 100;
const MAX_TOTAL_MACROS_G = 105;
const KJ_PER_KCAL = 4.184;
/** Density of ethanol: converts % by volume to grams per 100 ml. */
const ALCOHOL_G_PER_PCT = 0.789;
const MAX_KCAL_GAP = 40;
const MAX_KCAL_GAP_FRACTION = 0.3;

/** Lowercases, strips accents, and turns everything but a-z and 0-9 into single spaces. */
export function cleanText(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/\p{Mark}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

export function kcalFromKj(kj: number): number {
  return kj / KJ_PER_KCAL;
}

/** Energy implied by the macros, plus fibre and alcohol. */
export function expectedKcal(per100g: Per100g, alcoholPct = 0): number {
  return (
    4 * per100g.proteinG +
    4 * per100g.carbsG +
    9 * per100g.fatG +
    2 * (per100g.fiberG ?? 0) +
    7 * alcoholPct * ALCOHOL_G_PER_PCT
  );
}

function inRange(per100g: Per100g): boolean {
  const { kcal, proteinG, carbsG, fatG } = per100g;
  const macroInRange = (grams: number) => grams >= 0 && grams <= MAX_MACRO_G;
  return (
    kcal >= 0 &&
    kcal <= MAX_KCAL &&
    macroInRange(proteinG) &&
    macroInRange(carbsG) &&
    macroInRange(fatG) &&
    proteinG + carbsG + fatG <= MAX_TOTAL_MACROS_G
  );
}

function caloriesMatch(per100g: Per100g, alcoholPct?: number): boolean {
  const expected = expectedKcal(per100g, alcoholPct);
  const allowedGap = Math.max(MAX_KCAL_GAP, MAX_KCAL_GAP_FRACTION * Math.max(per100g.kcal, expected));
  return Math.abs(per100g.kcal - expected) <= allowedGap;
}

/** Rules 5 and 6: values in range, and calories that agree with the macros. */
export function isPlausible(per100g: Per100g, alcoholPct?: number): boolean {
  return inRange(per100g) && caloriesMatch(per100g, alcoholPct);
}

/** Rules 2, 3, 5 and 6, in that order. */
export function checkFood(food: FoodCandidate): FoodCheck {
  if (!BARCODE_PATTERN.test(food.barcode)) return { ok: false, rule: "barcode" };
  if (cleanText(food.name).replace(/ /g, "").length < MIN_NAME_LENGTH) {
    return { ok: false, rule: "name" };
  }
  if (!inRange(food.per100g)) return { ok: false, rule: "range" };
  if (!caloriesMatch(food.per100g, food.alcoholPct)) return { ok: false, rule: "calories" };
  return { ok: true };
}
