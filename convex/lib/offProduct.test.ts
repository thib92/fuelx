import { describe, expect, test } from "vitest";
import { offDoc, offRowFromApi, type OffApiProduct } from "./offProduct";

const product: OffApiProduct = {
  product_name: "Pâte à tartiner",
  product_name_fr: "Pâte à tartiner aux noisettes",
  brands: "Nutella, Ferrero",
  serving_quantity: 15,
  unique_scans_n: 42,
  nutriments: {
    "energy-kcal_100g": 539,
    "energy-kj_100g": 2252,
    energy_100g: 2252,
    proteins_100g: 6.3,
    carbohydrates_100g: 57.5,
    fat_100g: 30.9,
    sugars_100g: 56.3,
    fiber_100g: 0,
    salt_100g: 0.107,
  },
};
const barcode = "3017620422003";

describe("offRowFromApi", () => {
  test("maps the API shape to the import shape", () => {
    expect(offRowFromApi(barcode, product)).toEqual({
      code: barcode,
      name_fr: "Pâte à tartiner aux noisettes",
      name_main: "Pâte à tartiner",
      brands: "Nutella, Ferrero",
      kcal: 539,
      kj: 2252,
      proteins: 6.3,
      carbohydrates: 57.5,
      fat: 30.9,
      sugars: 56.3,
      fiber: 0,
      salt: 0.107,
      alcohol: null,
      serving_quantity: 15,
      unique_scans_n: 42,
    });
  });

  test("parses numbers sent as strings, and treats junk as missing", () => {
    const row = offRowFromApi(barcode, {
      nutriments: { proteins_100g: "6.3", fat_100g: "", sugars_100g: "n/a" },
    });
    expect(row).toMatchObject({ proteins: 6.3, fat: null, sugars: null });
  });

  test("falls back to `energy_100g`, which is in kJ", () => {
    const row = offRowFromApi(barcode, { nutriments: { energy_100g: 2252 } });
    expect(row).toMatchObject({ kcal: null, kj: 2252 });
  });

  test("copes with a product without nutriments", () => {
    expect(offRowFromApi(barcode, { nutriments: null }).kcal).toBeNull();
  });
});

describe("offDoc", () => {
  const row = offRowFromApi(barcode, product);

  test("builds a food, using the French name and first brand", () => {
    expect(offDoc(row)).toMatchObject({
      source: "off",
      sourceId: barcode,
      barcode,
      name: "Pâte à tartiner aux noisettes",
      brand: "Nutella",
      servingG: 15,
      offScans: 42,
      per100g: { kcal: 539, saltG: 0.11 },
    });
  });

  test("doesn't apply rule 7", () => {
    expect(offDoc({ ...row, brands: null, unique_scans_n: null })).not.toBeNull();
  });

  test("converts kJ when kcal is missing", () => {
    expect(offDoc({ ...row, kcal: null })?.per100g.kcal).toBe(538);
  });

  test("rejects missing macros and implausible calories", () => {
    expect(offDoc({ ...row, proteins: null })).toBeNull();
    expect(offDoc({ ...row, kcal: 20 })).toBeNull();
  });
});
