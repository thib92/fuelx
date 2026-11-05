import { expect, test } from "vitest";
import { entryNutrition, roundNutrition, sumNutrition } from "./logMath";

test("scales per 100 g values by grams", () => {
  expect(entryNutrition(150, { kcal: 110, proteinG: 23, carbsG: 0, fatG: 2 })).toEqual({
    kcal: 165,
    proteinG: 34.5,
    carbsG: 0,
    fatG: 3,
  });
});

test("sums items and returns zeros for none", () => {
  const item = { kcal: 10, proteinG: 1, carbsG: 2, fatG: 3 };
  expect(sumNutrition([item, item])).toEqual({ kcal: 20, proteinG: 2, carbsG: 4, fatG: 6 });
  expect(sumNutrition([])).toEqual({ kcal: 0, proteinG: 0, carbsG: 0, fatG: 0 });
});

test("rounds kcal to an integer and macros to 1 decimal", () => {
  expect(roundNutrition({ kcal: 164.6, proteinG: 34.56, carbsG: 0.04, fatG: 3.25 })).toEqual({
    kcal: 165,
    proteinG: 34.6,
    carbsG: 0,
    fatG: 3.3,
  });
});
