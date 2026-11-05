/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import { searchTextFor } from "./lib/foodSearch";
import schema, { type ImportDoc } from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts", "!./**/*.d.ts"]);

const per100g = { kcal: 350, proteinG: 12, carbsG: 70, fatG: 2 };

function publicFood(name: string, sourceId = name) {
  return {
    source: "ciqual" as const,
    sourceId,
    name,
    searchText: searchTextFor({ name }),
    per100g,
  };
}

function importDoc(sourceId: string, kcal = 350): ImportDoc {
  return {
    source: "off",
    sourceId,
    barcode: sourceId,
    name: "Skyr nature",
    brand: "Yoplait",
    searchText: "skyr nature yoplait",
    per100g: { ...per100g, kcal },
  };
}

const SECRET = "test-secret";

beforeEach(() => {
  vi.stubEnv("FOODS_IMPORT_SECRET", SECRET);
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("foods:search", () => {
  test("signed-out search returns nothing", async () => {
    const t = convexTest(schema, modules);
    await t.run((ctx) => ctx.db.insert("foods", publicFood("Riz blanc")));
    expect(await t.query(api.foods.search, { query: "riz" })).toEqual([]);
  });

  test("finds foods with accents in the query", async () => {
    const t = convexTest(schema, modules);
    await t.run((ctx) => ctx.db.insert("foods", publicFood("Pâtes complètes")));
    const results = await t.withIdentity({ subject: "alice" }).query(api.foods.search, {
      query: "pâtes",
    });
    expect(results.map((food) => food.name)).toEqual(["Pâtes complètes"]);
  });

  test.each(["", "!!!"])("query %j returns an empty list", async (query) => {
    const t = convexTest(schema, modules);
    await t.run((ctx) => ctx.db.insert("foods", publicFood("Riz blanc")));
    expect(
      await t.withIdentity({ subject: "alice" }).query(api.foods.search, { query }),
    ).toEqual([]);
  });

  test("a query of 30 words does not throw", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    const query = Array.from({ length: 30 }, (_, i) => `mot${i}`).join(" ");
    await expect(t.query(api.foods.search, { query })).resolves.toEqual([]);
  });

  test("custom foods are visible to their owner only", async () => {
    const t = convexTest(schema, modules);
    const alice = t.withIdentity({ subject: "alice" });
    await alice.mutation(api.foods.createCustom, { name: "Bowl maison", per100g });

    const found = await alice.query(api.foods.search, { query: "bowl" });
    expect(found.map((food) => food.name)).toEqual(["Bowl maison"]);
    expect(await t.withIdentity({ subject: "bob" }).query(api.foods.search, { query: "bowl" })).toEqual(
      [],
    );
  });

  test("generic foods surface even when hundreds of products match", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      for (let i = 0; i < 250; i += 1) {
        await ctx.db.insert("foods", { ...publicFood(`Riz marque ${i}`), source: "off" });
      }
      await ctx.db.insert("foods", publicFood("Riz blanc, cuit"));
    });
    const results = await t.withIdentity({ subject: "alice" }).query(api.foods.search, {
      query: "riz",
    });
    expect(results[0].name).toBe("Riz blanc, cuit");
  });

  test("pasta beats pâté whichever way pâtes is typed", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("foods", publicFood("Pâté breton"));
      await ctx.db.insert("foods", publicFood("Pâtes alimentaires, cuites"));
    });
    const alice = t.withIdentity({ subject: "alice" });
    const accented = await alice.query(api.foods.search, { query: "pâtes" });
    const plain = await alice.query(api.foods.search, { query: "pates" });
    expect(accented[0].name).toBe("Pâtes alimentaires, cuites");
    expect(plain[0].name).toBe("Pâtes alimentaires, cuites");
  });

  test("a generic food found by both searches appears once", async () => {
    const t = convexTest(schema, modules);
    await t.run((ctx) => ctx.db.insert("foods", publicFood("Riz blanc, cuit")));
    const results = await t.withIdentity({ subject: "alice" }).query(api.foods.search, {
      query: "riz",
    });
    expect(results).toHaveLength(1);
  });

  test("recent foods rank first", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("foods", publicFood("Riz blanc"));
      const recent = await ctx.db.insert("foods", publicFood("Riz complet"));
      await ctx.db.insert("recentFoods", {
        userId: "alice",
        foodId: recent,
        lastUsedAt: 1,
        useCount: 1,
        lastGrams: 80,
      });
    });
    const results = await t.withIdentity({ subject: "alice" }).query(api.foods.search, {
      query: "riz",
    });
    expect(results.map((food) => food.name)).toEqual(["Riz complet", "Riz blanc"]);
  });
});

describe("foods:createCustom", () => {
  test("requires sign-in", async () => {
    const t = convexTest(schema, modules);
    await expect(t.mutation(api.foods.createCustom, { name: "Bowl", per100g })).rejects.toThrow(
      "signed in",
    );
  });

  test("rejects implausible macros", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await expect(
      t.mutation(api.foods.createCustom, {
        name: "Bowl",
        per100g: { ...per100g, fatG: 200 },
      }),
    ).rejects.toThrow("values");
  });

  test("accepts drinks whose calories come from alcohol", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await expect(
      t.mutation(api.foods.createCustom, {
        name: "Vin rouge",
        per100g: { kcal: 85, proteinG: 0.1, carbsG: 2.6, fatG: 0 },
      }),
    ).resolves.toBeDefined();
  });

  test("rejects a blank name", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await expect(t.mutation(api.foods.createCustom, { name: "  ", per100g })).rejects.toThrow(
      "name",
    );
  });

  test("rejects a serving size that isn't positive", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await expect(
      t.mutation(api.foods.createCustom, { name: "Bowl", per100g, servingG: 0 }),
    ).rejects.toThrow("Serving");
  });
});

describe("foods:importBatch", () => {
  test("rejects a wrong secret", async () => {
    const t = convexTest(schema, modules);
    await expect(
      t.mutation(api.foods.importBatch, { secret: "wrong", docs: [importDoc("12345678")] }),
    ).rejects.toThrow("Not allowed");
  });

  test("rejects every secret when the env var is unset", async () => {
    vi.stubEnv("FOODS_IMPORT_SECRET", "");
    const t = convexTest(schema, modules);
    await expect(
      t.mutation(api.foods.importBatch, { secret: "", docs: [importDoc("12345678")] }),
    ).rejects.toThrow("Not allowed");
  });

  test("rejects more than 500 docs", async () => {
    const t = convexTest(schema, modules);
    const docs = Array.from({ length: 501 }, (_, i) => importDoc(String(i)));
    await expect(t.mutation(api.foods.importBatch, { secret: SECRET, docs })).rejects.toThrow("500");
  });

  test("inserts, updates changed docs and skips unchanged ones", async () => {
    const t = convexTest(schema, modules);
    const docs = [importDoc("12345678"), importDoc("87654321")];

    expect(await t.mutation(api.foods.importBatch, { secret: SECRET, docs })).toEqual({
      inserted: 2,
      updated: 0,
      unchanged: 0,
    });
    expect(await t.mutation(api.foods.importBatch, { secret: SECRET, docs })).toEqual({
      inserted: 0,
      updated: 0,
      unchanged: 2,
    });
    expect(
      await t.mutation(api.foods.importBatch, {
        secret: SECRET,
        docs: [importDoc("12345678", 360), docs[1]],
      }),
    ).toEqual({ inserted: 0, updated: 1, unchanged: 1 });
  });

  test("an update removes fields the new doc no longer has", async () => {
    const t = convexTest(schema, modules);
    await t.mutation(api.foods.importBatch, { secret: SECRET, docs: [importDoc("12345678")] });
    const { brand: _brand, ...withoutBrand } = importDoc("12345678");
    await t.mutation(api.foods.importBatch, { secret: SECRET, docs: [withoutBrand] });

    const [food] = await t.run((ctx) => ctx.db.query("foods").collect());
    expect(food.brand).toBeUndefined();
  });

  test("never touches label foods", async () => {
    const t = convexTest(schema, modules);
    const labelId = await t.run((ctx) =>
      ctx.db.insert("foods", {
        source: "label",
        sourceId: "12345678",
        barcode: "12345678",
        name: "Lu sur l'étiquette",
        searchText: "lu sur l etiquette",
        per100g,
      }),
    );

    await t.mutation(api.foods.importBatch, { secret: SECRET, docs: [importDoc("12345678", 360)] });

    const label = await t.run((ctx) => ctx.db.get(labelId));
    expect(label).toMatchObject({ name: "Lu sur l'étiquette", per100g });
  });
});
