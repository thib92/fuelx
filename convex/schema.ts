import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

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

export default defineSchema({
  profiles: defineTable({
    /** Better Auth user id (`identity.subject`). */
    userId: v.string(),
    ...profileInputFields,
  }).index("by_userId", ["userId"]),
});
