import { defineSchema, defineTable } from "convex/server";
import { type Infer, v } from "convex/values";

export const sexValidator = v.union(v.literal("male"), v.literal("female"));

/** Everyday activity, excluding workouts. */
export const activityLevelValidator = v.union(
  v.literal("sedentary"),
  v.literal("light"),
  v.literal("moderate"),
);

export const goalValidator = v.union(
  v.literal("lose"),
  v.literal("maintain"),
  v.literal("gain"),
);

/** What the user enters; everything needed to compute daily targets. */
export const profileInputFields = {
  sex: sexValidator,
  /** Local calendar date, "YYYY-MM-DD". */
  birthDate: v.string(),
  heightCm: v.number(),
  weightKg: v.number(),
  activityLevel: activityLevelValidator,
  goal: goalValidator,
  /** 0 when the goal is "maintain". */
  goalRateKgPerWeek: v.number(),
  proteinGPerKg: v.number(),
  /** Share of daily calories from fat, in percent. */
  fatPercent: v.number(),
};

/** Nutrition per 100 g. Sugar, fibre and salt are often missing from product data. */
export const per100gValidator = v.object({
  kcal: v.number(),
  proteinG: v.number(),
  carbsG: v.number(),
  fatG: v.number(),
  sugarG: v.optional(v.number()),
  fiberG: v.optional(v.number()),
  saltG: v.optional(v.number()),
});

export const foodSourceValidator = v.union(
  v.literal("ciqual"),
  v.literal("off"),
  v.literal("label"),
  v.literal("custom"),
);

const sharedFoodFields = {
  /** CIQUAL code, barcode, or a generated id. */
  sourceId: v.string(),
  barcode: v.optional(v.string()),
  name: v.string(),
  /** CIQUAL only. */
  nameEn: v.optional(v.string()),
  brand: v.optional(v.string()),
  /** From `searchTextFor` in lib/foodSearch.ts. */
  searchText: v.string(),
  per100g: per100gValidator,
  servingG: v.optional(v.number()),
  /** OFF's scan count. Only covers OFF's own apps, and is blank for many popular products. */
  offScans: v.optional(v.number()),
};

/** What the import scripts send to `foods:importBatch`. */
export const importDocValidator = v.object({
  source: v.union(v.literal("ciqual"), v.literal("off")),
  ...sharedFoodFields,
});
export type ImportDoc = Infer<typeof importDocValidator>;

export const mealValidator = v.union(
  v.literal("breakfast"),
  v.literal("lunch"),
  v.literal("dinner"),
  v.literal("snack"),
);
export type MealName = Infer<typeof mealValidator>;

/** Mirrors `Workout.Sport` in fuelx/Home/DayLog.swift. */
export const sportValidator = v.union(
  v.literal("run"),
  v.literal("ride"),
  v.literal("swim"),
  v.literal("strength"),
  v.literal("hike"),
  v.literal("walk"),
  v.literal("mobility"),
  v.literal("other"),
);

/** One workout as Apple Health reports it. See docs/superpowers/specs/ for what the values mean. */
export const workoutInputFields = {
  /** HealthKit UUID. */
  externalId: v.string(),
  /** The app that wrote the workout. */
  sourceBundleId: v.string(),
  /** Local calendar date, "YYYY-MM-DD". */
  day: v.string(),
  sport: sportValidator,
  /** Unix ms. */
  startAt: v.number(),
  durationSec: v.number(),
  kcal: v.optional(v.number()),
  basalKcal: v.optional(v.number()),
  distanceM: v.optional(v.number()),
  indoor: v.optional(v.boolean()),
};

export default defineSchema({
  profiles: defineTable({
    /** Better Auth user id (`identity.subject`). */
    userId: v.string(),
    ...profileInputFields,
  }).index("by_userId", ["userId"]),

  foods: defineTable({
    source: foodSourceValidator,
    ...sharedFoodFields,
    /** Set on "custom" foods, which are private to this user. */
    ownerId: v.optional(v.string()),
  })
    .index("by_barcode", ["barcode"])
    .index("by_source_sourceId", ["source", "sourceId"])
    .searchIndex("search_text", {
      searchField: "searchText",
      filterFields: ["source", "ownerId"],
    }),

  recentFoods: defineTable({
    userId: v.string(),
    foodId: v.id("foods"),
    lastUsedAt: v.number(),
    useCount: v.number(),
    lastGrams: v.number(),
  })
    .index("by_user_lastUsed", ["userId", "lastUsedAt"])
    .index("by_user_food", ["userId", "foodId"]),

  logEntries: defineTable({
    userId: v.string(),
    /** Local calendar date, "YYYY-MM-DD". */
    day: v.string(),
    meal: mealValidator,
    loggedAt: v.number(),
    /** Absent for AI-estimated items. */
    foodId: v.optional(v.id("foods")),
    /** Name, brand and nutrition are copied so food refreshes never change history. */
    name: v.string(),
    brand: v.optional(v.string()),
    grams: v.number(),
    per100g: per100gValidator,
    origin: v.union(
      v.literal("search"),
      v.literal("recent"),
      v.literal("barcode"),
      v.literal("photo"),
      v.literal("text"),
      v.literal("copy"),
    ),
    /** True when values came from the model, not a database food. */
    estimated: v.boolean(),
  }).index("by_user_day", ["userId", "day"]),

  workouts: defineTable({
    userId: v.string(),
    ...workoutInputFields,
  })
    .index("by_user_day", ["userId", "day"])
    .index("by_user_externalId", ["userId", "externalId"]),

  dailyActivity: defineTable({
    userId: v.string(),
    /** Local calendar date, "YYYY-MM-DD". */
    day: v.string(),
    steps: v.number(),
    /** Steps from a watch or tracker, not the phone. Absent when there are none. */
    wearableSteps: v.optional(v.number()),
  }).index("by_user_day", ["userId", "day"]),
});
