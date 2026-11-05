/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts", "!./**/*.d.ts"]);

const profile = {
  sex: "female" as const,
  birthDate: "1994-06-02",
  heightCm: 165,
  weightKg: 58,
  activityLevel: "moderate" as const,
  goal: "maintain" as const,
  goalRateKgPerWeek: 0,
  proteinGPerKg: 1.6,
  fatPercent: 25,
};

describe("profile", () => {
  test("requires sign-in to save; returns null when signed out", async () => {
    const t = convexTest(schema, modules);
    await expect(t.mutation(api.profile.upsert, profile)).rejects.toThrow("signed in");
    expect(await t.query(api.profile.get, {})).toBeNull();
  });

  test("upsert creates then updates the caller's own profile", async () => {
    const t = convexTest(schema, modules);
    const alice = t.withIdentity({ subject: "alice" });
    const bob = t.withIdentity({ subject: "bob" });

    await alice.mutation(api.profile.upsert, profile);
    await alice.mutation(api.profile.upsert, { ...profile, weightKg: 57 });

    expect(await alice.query(api.profile.get, {})).toMatchObject({ userId: "alice", weightKg: 57 });
    expect(await bob.query(api.profile.get, {})).toBeNull();
    const all = await t.run((ctx) => ctx.db.query("profiles").collect());
    expect(all).toHaveLength(1);
  });

  test("rejects out-of-range values", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await expect(t.mutation(api.profile.upsert, { ...profile, heightCm: 40 })).rejects.toThrow("Height");
    await expect(t.mutation(api.profile.upsert, { ...profile, birthDate: "2026-02-30" })).rejects.toThrow("Birth date");
    await expect(
      t.mutation(api.profile.upsert, { ...profile, goal: "gain", goalRateKgPerWeek: 1 }),
    ).rejects.toThrow("Rate");
    await expect(t.mutation(api.profile.upsert, { ...profile, fatPercent: 50 })).rejects.toThrow("Fat");
  });

  test("normalizes stepper floating-point noise", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    await t.mutation(api.profile.upsert, { ...profile, proteinGPerKg: 1.2 + 0.1 * 8 });
    expect((await t.query(api.profile.get, {}))?.proteinGPerKg).toBe(2);
  });

  test("transferOnLink moves the guest profile, or keeps the existing account's", async () => {
    const t = convexTest(schema, modules);
    await t.withIdentity({ subject: "guest1" }).mutation(api.profile.upsert, profile);
    await t.mutation(internal.profile.transferOnLink, { fromUserId: "guest1", toUserId: "apple" });
    expect(await t.withIdentity({ subject: "apple" }).query(api.profile.get, {})).toMatchObject({
      weightKg: 58,
    });

    await t.withIdentity({ subject: "guest2" }).mutation(api.profile.upsert, { ...profile, weightKg: 80 });
    await t.mutation(internal.profile.transferOnLink, { fromUserId: "guest2", toUserId: "apple" });
    expect(await t.withIdentity({ subject: "apple" }).query(api.profile.get, {})).toMatchObject({
      weightKg: 58,
    });
    expect(await t.run((ctx) => ctx.db.query("profiles").collect())).toHaveLength(1);
  });
});

describe("transferOnLink with logged data", () => {
  const per100g = { kcal: 110, proteinG: 23, carbsG: 0, fatG: 2 };
  const DAY = "2026-11-05";

  async function setup() {
    const t = convexTest(schema, modules);
    const foodId = await t.run((ctx) =>
      ctx.db.insert("foods", {
        source: "ciqual",
        sourceId: "1",
        name: "Poulet",
        searchText: "poulet",
        per100g,
      }),
    );
    const add = { day: DAY, meal: "lunch" as const, foodId, origin: "search" as const };
    return { t, foodId, add };
  }

  const link = { fromUserId: "guest", toUserId: "apple" };

  test("moves entries even when the guest has no profile", async () => {
    const { t, add } = await setup();
    await t.withIdentity({ subject: "guest" }).mutation(api.logs.add, { ...add, grams: 150 });

    await t.mutation(internal.profile.transferOnLink, link);

    const apple = t.withIdentity({ subject: "apple" });
    const log = await apple.query(api.logs.forDay, { day: DAY });
    expect(log?.entries).toHaveLength(1);
    const guest = t.withIdentity({ subject: "guest" });
    expect((await guest.query(api.logs.forDay, { day: DAY }))?.entries).toEqual([]);
  });

  test("keeps the existing account's entries and adds the guest's", async () => {
    const { t, add } = await setup();
    await t.withIdentity({ subject: "guest" }).mutation(api.logs.add, { ...add, grams: 150 });
    await t.withIdentity({ subject: "apple" }).mutation(api.logs.add, { ...add, grams: 200 });

    await t.mutation(internal.profile.transferOnLink, link);

    const log = await t.withIdentity({ subject: "apple" }).query(api.logs.forDay, { day: DAY });
    expect(log?.entries.map((entry) => entry.grams).sort()).toEqual([150, 200]);
  });

  test("merges recents: latest date and grams, summed counts", async () => {
    const { t, foodId } = await setup();
    await t.run(async (ctx) => {
      await ctx.db.insert("recentFoods", {
        userId: "guest",
        foodId,
        lastUsedAt: 200,
        useCount: 2,
        lastGrams: 80,
      });
      await ctx.db.insert("recentFoods", {
        userId: "apple",
        foodId,
        lastUsedAt: 100,
        useCount: 3,
        lastGrams: 120,
      });
    });

    await t.mutation(internal.profile.transferOnLink, link);

    const recents = await t.run((ctx) => ctx.db.query("recentFoods").collect());
    expect(recents).toHaveLength(1);
    expect(recents[0]).toMatchObject({
      userId: "apple",
      lastUsedAt: 200,
      useCount: 5,
      lastGrams: 80,
    });
  });

  test("merging keeps the account's grams when its recent is newer", async () => {
    const { t, foodId } = await setup();
    await t.run(async (ctx) => {
      await ctx.db.insert("recentFoods", {
        userId: "guest",
        foodId,
        lastUsedAt: 100,
        useCount: 1,
        lastGrams: 80,
      });
      await ctx.db.insert("recentFoods", {
        userId: "apple",
        foodId,
        lastUsedAt: 200,
        useCount: 1,
        lastGrams: 120,
      });
    });

    await t.mutation(internal.profile.transferOnLink, link);

    const [recent] = await t.run((ctx) => ctx.db.query("recentFoods").collect());
    expect(recent).toMatchObject({ lastUsedAt: 200, lastGrams: 120 });
  });

  test("moves a recent the account doesn't have", async () => {
    const { t, add } = await setup();
    await t.withIdentity({ subject: "guest" }).mutation(api.logs.add, { ...add, grams: 150 });

    await t.mutation(internal.profile.transferOnLink, link);

    const recents = await t.withIdentity({ subject: "apple" }).query(api.logs.recents, {});
    expect(recents.map((recent) => recent.name)).toEqual(["Poulet"]);
  });

  test("moves custom foods, which stay searchable by the new owner", async () => {
    const { t } = await setup();
    await t
      .withIdentity({ subject: "guest" })
      .mutation(api.foods.createCustom, { name: "Bowl maison", per100g });

    await t.mutation(internal.profile.transferOnLink, link);

    const apple = t.withIdentity({ subject: "apple" });
    const found = await apple.query(api.foods.search, { query: "bowl" });
    expect(found.map((food) => food.name)).toEqual(["Bowl maison"]);
    const guest = t.withIdentity({ subject: "guest" });
    expect(await guest.query(api.foods.search, { query: "bowl" })).toEqual([]);
  });

  test("leaves other users' custom foods alone", async () => {
    const { t } = await setup();
    await t
      .withIdentity({ subject: "bob" })
      .mutation(api.foods.createCustom, { name: "Bowl de bob", per100g });

    await t.mutation(internal.profile.transferOnLink, link);

    const bob = t.withIdentity({ subject: "bob" });
    expect(await bob.query(api.foods.search, { query: "bowl" })).toHaveLength(1);
  });
});

describe("nutrition.targetsForDay", () => {
  test("null without a profile; computed targets with one", async () => {
    const t = convexTest(schema, modules).withIdentity({ subject: "alice" });
    expect(await t.query(api.nutrition.targetsForDay, { day: "2026-10-31" })).toBeNull();

    await t.mutation(api.profile.upsert, profile);
    const targets = await t.query(api.nutrition.targetsForDay, { day: "2026-10-31" });
    expect(targets).toMatchObject({ day: "2026-10-31", age: 32, proteinG: 93 });
    await expect(t.query(api.nutrition.targetsForDay, { day: "yesterday" })).rejects.toThrow("YYYY-MM-DD");
  });
});
