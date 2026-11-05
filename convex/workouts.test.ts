/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "./_generated/api";
import { GARMIN_CONNECT_BUNDLE_ID } from "./lib/workouts";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts", "!./**/*.d.ts"]);

const DAY = "2026-11-04";
const START = Date.UTC(2026, 10, 4, 18);

const workout = (externalId: string, overrides = {}) => ({
  externalId,
  sourceBundleId: GARMIN_CONNECT_BUNDLE_ID,
  day: DAY,
  sport: "swim" as const,
  startAt: START,
  durationSec: 2820,
  kcal: 584,
  basalKcal: 80,
  distanceM: 2100,
  indoor: true,
  ...overrides,
});

const syncArgs = (workouts: ReturnType<typeof workout>[], extra = {}) => ({
  workouts,
  deletedIds: [],
  steps: [],
  ...extra,
});

function setup() {
  const t = convexTest(schema, modules);
  return { t, alice: t.withIdentity({ subject: "alice" }), bob: t.withIdentity({ subject: "bob" }) };
}

describe("workouts:sync", () => {
  test("requires sign-in", async () => {
    const { t } = setup();
    await expect(t.mutation(api.workouts.sync, syncArgs([]))).rejects.toThrow("signed in");
  });

  test("repeating a sync changes nothing, and new values replace old ones", async () => {
    const { alice } = setup();
    await alice.mutation(api.workouts.sync, syncArgs([workout("a")]));
    await alice.mutation(api.workouts.sync, syncArgs([workout("a", { kcal: 600 })]));
    const result = await alice.query(api.workouts.forDay, { day: DAY });
    expect(result?.workouts.map((w) => w.activeKcal)).toEqual([600]);
  });

  test("deletes by external id, and ignores ones it never saw", async () => {
    const { alice } = setup();
    await alice.mutation(api.workouts.sync, syncArgs([workout("a")]));
    await alice.mutation(api.workouts.sync, syncArgs([], { deletedIds: ["a", "unknown"] }));
    expect((await alice.query(api.workouts.forDay, { day: DAY }))?.workouts).toEqual([]);
  });

  test("the same Health id can belong to two users", async () => {
    const { alice, bob } = setup();
    await alice.mutation(api.workouts.sync, syncArgs([workout("a")]));
    await bob.mutation(api.workouts.sync, syncArgs([workout("a")]));
    await bob.mutation(api.workouts.sync, syncArgs([], { deletedIds: ["a"] }));
    expect((await alice.query(api.workouts.forDay, { day: DAY }))?.workouts).toHaveLength(1);
  });

  test("steps overwrite the day's value", async () => {
    const { alice } = setup();
    await alice.mutation(api.workouts.sync, syncArgs([], { steps: [{ day: DAY, steps: 305 }] }));
    await alice.mutation(api.workouts.sync, syncArgs([], { steps: [{ day: DAY, steps: 9000 }] }));
    expect((await alice.query(api.workouts.forDay, { day: DAY }))?.steps).toBe(9000);
  });

  test("shows watch steps over the merged total, and the total without a watch", async () => {
    const { alice } = setup();
    await alice.mutation(
      api.workouts.sync,
      syncArgs([], {
        steps: [
          { day: DAY, steps: 28905, wearableSteps: 3405 },
          { day: "2026-11-03", steps: 305 },
        ],
      }),
    );
    expect((await alice.query(api.workouts.forDay, { day: DAY }))?.steps).toBe(3405);
    expect((await alice.query(api.workouts.forDay, { day: "2026-11-03" }))?.steps).toBe(305);
  });

  test("rejects bad input and oversized batches", async () => {
    const { alice } = setup();
    await expect(
      alice.mutation(api.workouts.sync, syncArgs([workout("a", { day: "tomorrow" })])),
    ).rejects.toThrow("YYYY-MM-DD");
    await expect(
      alice.mutation(api.workouts.sync, syncArgs([workout("a", { kcal: -1 })])),
    ).rejects.toThrow("invalid numbers");
    await expect(
      alice.mutation(api.workouts.sync, syncArgs([], { deletedIds: Array(201).fill("a") })),
    ).rejects.toThrow("at most");
  });
});

describe("workouts:forDay", () => {
  test("is null when signed out", async () => {
    const { t } = setup();
    expect(await t.query(api.workouts.forDay, { day: DAY })).toBeNull();
  });

  test("only shows the caller's workouts", async () => {
    const { alice, bob } = setup();
    await alice.mutation(api.workouts.sync, syncArgs([workout("a")]));
    expect((await bob.query(api.workouts.forDay, { day: DAY }))?.workouts).toEqual([]);
  });

  test("sorts by start and hides multisport parents", async () => {
    const { alice } = setup();
    const hour = 3_600_000;
    await alice.mutation(
      api.workouts.sync,
      syncArgs([
        workout("run", { sport: "run", startAt: START + hour, durationSec: 1800 }),
        workout("swim", { durationSec: 1800 }),
        workout("parent", { sport: "other", durationSec: 5400, kcal: 2000, basalKcal: undefined }),
      ]),
    );
    const result = await alice.query(api.workouts.forDay, { day: DAY });
    expect(result?.workouts.map((w) => w.sport)).toEqual(["swim", "run"]);
  });

  test("takes resting energy off an upload using the profile's BMR", async () => {
    const { t, alice } = setup();
    await t.run((ctx) =>
      ctx.db.insert("profiles", {
        userId: "alice",
        sex: "male",
        birthDate: "1990-01-01",
        heightCm: 180,
        weightKg: 70,
        activityLevel: "sedentary",
        goal: "maintain",
        goalRateKgPerWeek: 0,
        proteinGPerKg: 1.6,
        fatPercent: 25,
      }),
    );
    const rouvy = workout("rouvy", { sport: "ride", durationSec: 4200, kcal: 774, basalKcal: undefined });
    await alice.mutation(api.workouts.sync, syncArgs([rouvy]));
    const result = await alice.query(api.workouts.forDay, { day: DAY });
    // BMR 1,650 kcal/day over 70 minutes is about 80 kcal.
    expect(result?.workouts[0].activeKcal).toBe(694);
  });
});

describe("nutrition:targetsForDay with steps", () => {
  const profile = {
    userId: "alice",
    sex: "male" as const,
    birthDate: "1990-01-01",
    heightCm: 180,
    weightKg: 70,
    activityLevel: "moderate" as const,
    goal: "maintain" as const,
    goalRateKgPerWeek: 0,
    proteinGPerKg: 1.6,
    fatPercent: 25,
  };

  async function withSteps(steps: { steps: number; wearableSteps?: number }, workouts = [] as ReturnType<typeof workout>[]) {
    const { t, alice } = setup();
    await t.run((ctx) => ctx.db.insert("profiles", profile));
    await alice.mutation(api.workouts.sync, syncArgs(workouts, { steps: [{ day: DAY, ...steps }] }));
    return alice.query(api.nutrition.targetsForDay, { day: DAY });
  }

  test("uses watch steps, without the run", async () => {
    const run = workout("run", { sport: "run", durationSec: 3600 });
    expect((await withSteps({ steps: 16000, wearableSteps: 16000 }, [run]))?.stepsUsed).toBe(6100);
  });

  test("falls back to the activity level for phone-only steps", async () => {
    expect((await withSteps({ steps: 8000 }))?.stepsUsed).toBeUndefined();
  });

  test("falls back when the watch probably wasn't worn", async () => {
    expect((await withSteps({ steps: 900, wearableSteps: 900 }))?.stepsUsed).toBeUndefined();
  });

  test("today keeps the activity level until steps pass it", async () => {
    const { t, alice } = setup();
    await t.run((ctx) => ctx.db.insert("profiles", profile));
    await alice.mutation(api.workouts.sync, syncArgs([], { steps: [{ day: DAY, steps: 3000, wearableSteps: 3000 }] }));
    const finished = await alice.query(api.nutrition.targetsForDay, { day: DAY });
    const today = await alice.query(api.nutrition.targetsForDay, { day: DAY, inProgress: true });
    expect(finished?.stepsUsed).toBe(3000);
    expect(today?.stepsUsed).toBeUndefined();
    expect(today!.calories).toBeGreaterThan(finished!.calories);
  });
});

describe("guest upgrade", () => {
  test("moves workouts and steps, merging what the account already has", async () => {
    const { t, alice, bob } = setup();
    await alice.mutation(
      api.workouts.sync,
      syncArgs([workout("shared"), workout("guest-only", { startAt: START + 7_200_000 })], {
        steps: [{ day: DAY, steps: 9000 }, { day: "2026-11-03", steps: 100 }],
      }),
    );
    await bob.mutation(
      api.workouts.sync,
      syncArgs([workout("shared")], { steps: [{ day: DAY, steps: 500 }] }),
    );

    await t.mutation(internal.profile.transferOnLink, { fromUserId: "alice", toUserId: "bob" });

    const today = await bob.query(api.workouts.forDay, { day: DAY });
    expect(today?.workouts).toHaveLength(2);
    expect(today?.steps).toBe(9000);
    expect((await bob.query(api.workouts.forDay, { day: "2026-11-03" }))?.steps).toBe(100);
    expect((await alice.query(api.workouts.forDay, { day: DAY }))?.workouts).toEqual([]);
  });
});
