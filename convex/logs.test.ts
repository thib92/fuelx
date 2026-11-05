/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts", "!./**/*.d.ts"]);

const DAY = "2026-11-05";
const YESTERDAY = "2026-11-04";
const per100g = { kcal: 110, proteinG: 23, carbsG: 0, fatG: 2 };

async function setup() {
  const t = convexTest(schema, modules);
  const foodId = await t.run((ctx) =>
    ctx.db.insert("foods", {
      source: "ciqual",
      sourceId: "36017",
      name: "Poulet, filet",
      searchText: "poulet filet",
      per100g,
    }),
  );
  return {
    t,
    foodId,
    alice: t.withIdentity({ subject: "alice" }),
    bob: t.withIdentity({ subject: "bob" }),
  };
}

const addArgs = (foodId: Awaited<ReturnType<typeof setup>>["foodId"], grams = 150) => ({
  day: DAY,
  meal: "lunch" as const,
  foodId,
  grams,
  origin: "search" as const,
});

describe("logs:add", () => {
  test("requires sign-in", async () => {
    const { t, foodId } = await setup();
    await expect(t.mutation(api.logs.add, addArgs(foodId))).rejects.toThrow("signed in");
  });

  test("snapshots the food, so editing the food later changes nothing", async () => {
    const { t, alice, foodId } = await setup();
    await alice.mutation(api.logs.add, addArgs(foodId));
    await t.run((ctx) => ctx.db.patch(foodId, { per100g: { ...per100g, kcal: 999 } }));

    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries[0]).toMatchObject({ name: "Poulet, filet", grams: 150, kcal: 165 });
  });

  test("creates a recent; a second add bumps useCount and lastGrams", async () => {
    const { t, alice, foodId } = await setup();
    await alice.mutation(api.logs.add, addArgs(foodId, 150));
    await alice.mutation(api.logs.add, addArgs(foodId, 200));

    const recents = await t.run((ctx) => ctx.db.query("recentFoods").collect());
    expect(recents).toHaveLength(1);
    expect(recents[0]).toMatchObject({ userId: "alice", useCount: 2, lastGrams: 200 });
  });

  test.each([0, -5, NaN, Infinity, 5001])("rejects grams %s", async (grams) => {
    const { alice, foodId } = await setup();
    await expect(alice.mutation(api.logs.add, addArgs(foodId, grams))).rejects.toThrow("Grams");
  });

  test("rejects a malformed day", async () => {
    const { alice, foodId } = await setup();
    await expect(
      alice.mutation(api.logs.add, { ...addArgs(foodId), day: "05/11/2026" }),
    ).rejects.toThrow("Day");
  });

  test("a food owned by another user cannot be logged", async () => {
    const { alice, bob } = await setup();
    const food = await alice.mutation(api.foods.createCustom, { name: "Bowl maison", per100g });
    await expect(bob.mutation(api.logs.add, addArgs(food))).rejects.toThrow("not found");
  });
});

describe("logs:forDay", () => {
  test("returns null when signed out", async () => {
    const { t } = await setup();
    expect(await t.query(api.logs.forDay, { day: DAY })).toBeNull();
  });

  test("rejects a malformed day", async () => {
    const { alice } = await setup();
    await expect(alice.query(api.logs.forDay, { day: "yesterday" })).rejects.toThrow("Day");
  });

  test("an empty day has zero totals for every meal", async () => {
    const { alice } = await setup();
    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries).toEqual([]);
    expect(log?.totals.kcal).toBe(0);
    expect(Object.keys(log?.mealTotals ?? {}).sort()).toEqual([
      "breakfast",
      "dinner",
      "lunch",
      "snack",
    ]);
  });

  test("totals sum unrounded values", async () => {
    const { t, alice } = await setup();
    const foodId = await t.run((ctx) =>
      ctx.db.insert("foods", {
        source: "ciqual",
        sourceId: "1",
        name: "Test",
        searchText: "test",
        per100g: { kcal: 100, proteinG: 0, carbsG: 0, fatG: 0 },
      }),
    );
    for (let i = 0; i < 3; i += 1) {
      await alice.mutation(api.logs.add, addArgs(foodId, 1.5));
    }

    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries.map((entry) => entry.kcal)).toEqual([2, 2, 2]);
    expect(log?.totals.kcal).toBe(5);
    expect(log?.mealTotals.lunch.kcal).toBe(5);
    expect(log?.mealTotals.dinner.kcal).toBe(0);
  });

  test("entries are private to their owner", async () => {
    const { alice, bob, foodId } = await setup();
    await alice.mutation(api.logs.add, addArgs(foodId));
    const log = await bob.query(api.logs.forDay, { day: DAY });
    expect(log?.entries).toEqual([]);
  });
});

describe("logs:update and logs:remove", () => {
  test("update changes grams but keeps the snapshot", async () => {
    const { t, alice, foodId } = await setup();
    const id = await alice.mutation(api.logs.add, addArgs(foodId));
    await t.run((ctx) => ctx.db.patch(foodId, { per100g: { ...per100g, kcal: 999 } }));

    await alice.mutation(api.logs.update, { id, grams: 300 });

    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries[0]).toMatchObject({ grams: 300, kcal: 330 });
  });

  test("update can move an entry to another meal", async () => {
    const { alice, foodId } = await setup();
    const id = await alice.mutation(api.logs.add, addArgs(foodId));
    await alice.mutation(api.logs.update, { id, meal: "dinner" });
    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries[0].meal).toBe("dinner");
  });

  test("update rejects invalid grams", async () => {
    const { alice, foodId } = await setup();
    const id = await alice.mutation(api.logs.add, addArgs(foodId));
    await expect(alice.mutation(api.logs.update, { id, grams: 0 })).rejects.toThrow("Grams");
  });

  test("another user can't update or remove an entry", async () => {
    const { alice, bob, foodId } = await setup();
    const id = await alice.mutation(api.logs.add, addArgs(foodId));
    await expect(bob.mutation(api.logs.update, { id, grams: 1 })).rejects.toThrow("not found");
    await expect(bob.mutation(api.logs.remove, { id })).rejects.toThrow("not found");
  });

  test("remove deletes the entry", async () => {
    const { alice, foodId } = await setup();
    const id = await alice.mutation(api.logs.add, addArgs(foodId));
    await alice.mutation(api.logs.remove, { id });
    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries).toEqual([]);
  });
});

describe("logs:copyMeal", () => {
  const copy = { fromDay: YESTERDAY, toDay: DAY, meal: "lunch" as const };

  test("copies snapshots with origin copy and returns the count", async () => {
    const { t, alice, foodId } = await setup();
    await alice.mutation(api.logs.add, { ...addArgs(foodId), day: YESTERDAY });
    await alice.mutation(api.logs.add, { ...addArgs(foodId), day: YESTERDAY, meal: "dinner" });
    await t.run((ctx) => ctx.db.patch(foodId, { per100g: { ...per100g, kcal: 999 } }));

    expect(await alice.mutation(api.logs.copyMeal, copy)).toBe(1);

    const entries = await t.run((ctx) => ctx.db.query("logEntries").collect());
    const copied = entries.filter((entry) => entry.day === DAY);
    expect(copied).toHaveLength(1);
    expect(copied[0]).toMatchObject({ origin: "copy", meal: "lunch", grams: 150, per100g });
  });

  test("returns 0 for an empty source meal", async () => {
    const { alice } = await setup();
    expect(await alice.mutation(api.logs.copyMeal, copy)).toBe(0);
  });

  test("rejects copying a meal onto itself", async () => {
    const { alice, foodId } = await setup();
    await alice.mutation(api.logs.add, addArgs(foodId));
    await expect(
      alice.mutation(api.logs.copyMeal, { ...copy, fromDay: DAY }),
    ).rejects.toThrow("different day");
  });

  test("still copies an entry without a food", async () => {
    const { t, alice } = await setup();
    await t.run((ctx) =>
      ctx.db.insert("logEntries", {
        userId: "alice",
        day: YESTERDAY,
        meal: "lunch",
        loggedAt: 1,
        name: "Estimated curry",
        grams: 300,
        per100g,
        origin: "photo",
        estimated: true,
      }),
    );

    expect(await alice.mutation(api.logs.copyMeal, copy)).toBe(1);

    const log = await alice.query(api.logs.forDay, { day: DAY });
    expect(log?.entries[0]).toMatchObject({ name: "Estimated curry", estimated: true });
  });

  test("doesn't copy another user's entries", async () => {
    const { alice, bob, foodId } = await setup();
    await alice.mutation(api.logs.add, { ...addArgs(foodId), day: YESTERDAY });
    expect(await bob.mutation(api.logs.copyMeal, copy)).toBe(0);
  });
});

describe("logs:recents", () => {
  test("returns nothing when signed out", async () => {
    const { t } = await setup();
    expect(await t.query(api.logs.recents, {})).toEqual([]);
  });

  test("returns the food's current data and lastGrams, newest first", async () => {
    const { t, alice, foodId } = await setup();
    const other = await t.run((ctx) =>
      ctx.db.insert("foods", {
        source: "ciqual",
        sourceId: "2",
        name: "Riz",
        searchText: "riz",
        per100g,
      }),
    );
    await alice.mutation(api.logs.add, addArgs(foodId, 150));
    await alice.mutation(api.logs.add, addArgs(other, 80));
    await t.run((ctx) => ctx.db.patch(other, { name: "Riz blanc" }));

    const recents = await alice.query(api.logs.recents, {});
    expect(recents.map((recent) => [recent.name, recent.lastGrams])).toEqual([
      ["Riz blanc", 80],
      ["Poulet, filet", 150],
    ]);
  });

  test("honours the limit", async () => {
    const { t, alice, foodId } = await setup();
    const other = await t.run((ctx) =>
      ctx.db.insert("foods", { source: "ciqual", sourceId: "2", name: "Riz", searchText: "riz", per100g }),
    );
    await alice.mutation(api.logs.add, addArgs(foodId));
    await alice.mutation(api.logs.add, addArgs(other));
    expect(await alice.query(api.logs.recents, { limit: 1 })).toHaveLength(1);
  });
});
