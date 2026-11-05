import type { Per100g } from "./foodQuality";

export type Nutrition = {
  kcal: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
};

/** Nutrition for an amount of food, unrounded so totals stay accurate. */
export function entryNutrition(grams: number, per100g: Per100g): Nutrition {
  const scale = grams / 100;
  return {
    kcal: per100g.kcal * scale,
    proteinG: per100g.proteinG * scale,
    carbsG: per100g.carbsG * scale,
    fatG: per100g.fatG * scale,
  };
}

export function sumNutrition(items: Nutrition[]): Nutrition {
  return items.reduce(
    (total, item) => ({
      kcal: total.kcal + item.kcal,
      proteinG: total.proteinG + item.proteinG,
      carbsG: total.carbsG + item.carbsG,
      fatG: total.fatG + item.fatG,
    }),
    { kcal: 0, proteinG: 0, carbsG: 0, fatG: 0 },
  );
}

/** Rounds for display: whole kcal, macros to 1 decimal. */
export function roundNutrition(nutrition: Nutrition): Nutrition {
  const oneDecimal = (grams: number) => Math.round(grams * 10) / 10;
  return {
    kcal: Math.round(nutrition.kcal),
    proteinG: oneDecimal(nutrition.proteinG),
    carbsG: oneDecimal(nutrition.carbsG),
    fatG: oneDecimal(nutrition.fatG),
  };
}
