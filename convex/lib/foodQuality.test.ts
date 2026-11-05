import { describe, expect, test } from "vitest";
import {
  checkFood,
  cleanText,
  expectedKcal,
  isInRange,
  isPlausible,
  kcalFromKj,
} from "./foodQuality";

const clean = {
  barcode: "3017620422003",
  name: "Pâte à tartiner",
  per100g: { kcal: 539, proteinG: 6.3, carbsG: 57.5, fatG: 30.9 },
};

describe("checkFood", () => {
  test("accepts a normal product", () => {
    expect(checkFood(clean)).toEqual({ ok: true });
  });

  test.each(["12345", "abcdefghijklm", "123456789"])("rejects barcode %s", (barcode) => {
    expect(checkFood({ ...clean, barcode })).toEqual({ ok: false, rule: "barcode" });
  });

  test.each(["12345678", "123456789012", "1234567890123", "12345678901234"])(
    "accepts barcode %s",
    (barcode) => {
      expect(checkFood({ ...clean, barcode }).ok).toBe(true);
    },
  );

  test("rejects names under 3 alphanumerics after cleaning", () => {
    expect(checkFood({ ...clean, name: "a!" })).toEqual({ ok: false, rule: "name" });
  });

  test("rejects non-Latin-only names", () => {
    expect(checkFood({ ...clean, name: "زيت" })).toEqual({ ok: false, rule: "name" });
  });

  test("rejects kcal over 950", () => {
    expect(checkFood({ ...clean, per100g: { ...clean.per100g, kcal: 951 } })).toEqual({
      ok: false,
      rule: "range",
    });
  });

  test("rejects macros over 105 g in total", () => {
    expect(
      checkFood({ ...clean, per100g: { kcal: 400, proteinG: 40, carbsG: 40, fatG: 26 } }),
    ).toEqual({ ok: false, rule: "range" });
  });

  test("rejects butter listed at half its energy", () => {
    expect(
      checkFood({ ...clean, per100g: { kcal: 375, proteinG: 0.7, carbsG: 0.6, fatG: 82 } }),
    ).toEqual({ ok: false, rule: "calories" });
  });

  test("accepts water", () => {
    expect(
      checkFood({ ...clean, per100g: { kcal: 0, proteinG: 0, carbsG: 0, fatG: 0 } }).ok,
    ).toBe(true);
  });

  test("counts alcohol energy: pastis passes", () => {
    expect(
      checkFood({
        ...clean,
        per100g: { kcal: 274, proteinG: 0, carbsG: 0, fatG: 0 },
        alcoholPct: 45,
      }).ok,
    ).toBe(true);
  });

  test("counts fibre energy", () => {
    expect(
      checkFood({
        ...clean,
        per100g: { kcal: 240, proteinG: 10, carbsG: 20, fatG: 5, fiberG: 40 },
      }).ok,
    ).toBe(true);
  });
});

describe("helpers", () => {
  test("expectedKcal applies the spec formula", () => {
    expect(expectedKcal({ kcal: 0, proteinG: 10, carbsG: 20, fatG: 5, fiberG: 3 }, 10)).toBeCloseTo(
      40 + 80 + 45 + 6 + 55.23,
      2,
    );
  });

  test("isPlausible rejects a negative macro", () => {
    expect(isPlausible({ kcal: 100, proteinG: -1, carbsG: 20, fatG: 2 })).toBe(false);
  });

  test("kcalFromKj converts at 4.184", () => {
    expect(kcalFromKj(418.4)).toBeCloseTo(100, 5);
  });

  test("cleanText lowercases, strips accents and collapses punctuation", () => {
    expect(cleanText("  Crème-Brûlée, 100%! ")).toBe("creme brulee 100");
  });

  test.each([
    ["Bœuf haché", "boeuf hache"],
    ["ŒUF", "oeuf"],
    ["cœur de laitue", "coeur de laitue"],
    ["Lætitia", "laetitia"],
    ["Æble", "aeble"],
  ])("cleanText expands the ligature in %s", (input, want) => {
    expect(cleanText(input)).toBe(want);
  });

  test("a ligature name keeps its full length for rule 3", () => {
    expect(checkFood({ ...clean, name: "Œuf" }).ok).toBe(true);
  });

  test("isInRange ignores whether calories match the macros", () => {
    const wine = { kcal: 85, proteinG: 0.1, carbsG: 2.6, fatG: 0 };
    expect(isPlausible(wine)).toBe(false);
    expect(isInRange(wine)).toBe(true);
    expect(isInRange({ ...wine, fatG: 200 })).toBe(false);
  });
});
