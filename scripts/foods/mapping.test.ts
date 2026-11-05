import { describe, expect, test } from "vitest";
import {
  ciqualFood,
  offFood,
  parseCiqualFoods,
  parseCiqualValue,
  parseCiqualValues,
  type OffRow,
} from "./mapping";

describe("parseCiqualValue", () => {
  test.each([
    ["12,3", 12.3],
    [" 12,3 ", 12.3],
    ["traces", 0],
    ["< 0,5", 0.5],
    ["-", undefined],
    ["", undefined],
    ["n/a", undefined],
  ])("parses %j", (raw, want) => {
    expect(parseCiqualValue(raw)).toBe(want);
  });
});

describe("CIQUAL XML", () => {
  test("reads foods and decodes entities", () => {
    const xml = `<TABLE><ALIM>
      <alim_code> 1000 </alim_code>
      <alim_nom_fr> Crème &amp; lait </alim_nom_fr>
      <alim_nom_eng> Jones&apos; cream </alim_nom_eng>
    </ALIM></TABLE>`;
    expect(parseCiqualFoods(xml)).toEqual([
      { code: "1000", nameFr: "Crème & lait", nameEn: "Jones' cream" },
    ]);
  });

  test("reads tracked nutrients and skips other constituents and blank values", () => {
    const xml = `<TABLE>
      <COMPO><alim_code> 1000 </alim_code><const_code> 328 </const_code><teneur> 274 </teneur></COMPO>
      <COMPO><alim_code> 1000 </alim_code><const_code> 25000 </const_code><teneur> 1,5 </teneur></COMPO>
      <COMPO><alim_code> 1000 </alim_code><const_code> 327 </const_code><teneur> 1140 </teneur></COMPO>
      <COMPO><alim_code> 1000 </alim_code><const_code> 40000 </const_code><teneur missing=" " /></COMPO>
    </TABLE>`;
    expect(parseCiqualValues(xml).get("1000")).toEqual({ kcal: 274, proteinG: 1.5 });
  });
});

describe("ciqualFood", () => {
  const values = { kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6 };

  test("builds a document with French and English search text", () => {
    expect(ciqualFood("36018", "Poulet, filet", "Chicken, breast", values)).toEqual({
      source: "ciqual",
      sourceId: "36018",
      name: "Poulet, filet",
      nameEn: "Chicken, breast",
      searchText: "poulet filet chicken breast",
      per100g: values,
    });
  });

  test("computes missing kcal from macros", () => {
    const food = ciqualFood("1", "Riz", "Rice", { proteinG: 20, carbsG: 10, fatG: 5 });
    expect(food?.per100g.kcal).toBe(165);
  });

  test("drops foods missing a macro", () => {
    expect(ciqualFood("1", "Riz", "Rice", { kcal: 100, proteinG: 2, carbsG: 20 })).toBeNull();
  });
});

describe("offFood", () => {
  const row: OffRow = {
    code: "3329770077003",
    name_fr: "Skyr nature",
    name_main: "Plain skyr",
    brands: "Yoplait, Sodiaal",
    kcal: 57,
    kj: null,
    proteins: 10.07,
    carbohydrates: 3.9,
    fat: 0.2,
    sugars: 3.94,
    fiber: null,
    salt: 0.104,
    alcohol: null,
    serving_quantity: "150",
    unique_scans_n: 1023,
  };

  test("prefers the French name, keeps the first brand, and rounds", () => {
    expect(offFood(row)).toEqual({
      source: "off",
      sourceId: "3329770077003",
      barcode: "3329770077003",
      name: "Skyr nature",
      brand: "Yoplait",
      searchText: "skyr nature yoplait",
      per100g: { kcal: 57, proteinG: 10.1, carbsG: 3.9, fatG: 0.2, sugarG: 3.9, saltG: 0.1 },
      servingG: 150,
      offScans: 1023,
    });
  });

  test("falls back to the main name", () => {
    expect(offFood({ ...row, name_fr: null })?.name).toBe("Plain skyr");
  });

  test("uses kJ when kcal is missing", () => {
    expect(offFood({ ...row, kcal: null, kj: 238.5 })?.per100g.kcal).toBe(57);
  });

  test("drops a product with neither brand nor scans (rule 7)", () => {
    expect(offFood({ ...row, brands: null, unique_scans_n: null })).toBeNull();
    expect(offFood({ ...row, brands: "  ", unique_scans_n: 0 })).toBeNull();
  });

  test("keeps a scanned product without a brand", () => {
    const food = offFood({ ...row, brands: null });
    expect(food?.brand).toBeUndefined();
    expect(food?.offScans).toBe(1023);
  });

  test("keeps a branded product without scans", () => {
    expect(offFood({ ...row, unique_scans_n: null })?.offScans).toBeUndefined();
  });

  test("drops a product that fails the quality rules", () => {
    expect(offFood({ ...row, code: "123" })).toBeNull();
    expect(offFood({ ...row, proteins: null })).toBeNull();
    expect(offFood({ ...row, kcal: 900 })).toBeNull();
  });

  test("counts alcohol in the calorie check", () => {
    const pastis = { ...row, kcal: 274, proteins: 0, carbohydrates: 0, fat: 0, alcohol: 45 };
    expect(offFood(pastis)).not.toBeNull();
    expect(offFood({ ...pastis, alcohol: null })).toBeNull();
  });

  test("omits missing optional fields", () => {
    const food = offFood({ ...row, sugars: null, salt: null, serving_quantity: null });
    expect(food?.per100g).toEqual({ kcal: 57, proteinG: 10.1, carbsG: 3.9, fatG: 0.2 });
    expect(food).not.toHaveProperty("servingG");
  });

  test.each(["0", "-5", "6000", "abc"])("ignores serving quantity %s", (serving_quantity) => {
    expect(offFood({ ...row, serving_quantity })).not.toHaveProperty("servingG");
  });
});
