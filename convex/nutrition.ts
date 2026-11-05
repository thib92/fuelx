import { ConvexError, v } from "convex/values";
import { query } from "./_generated/server";
import { computeTargets, parseDay } from "./lib/nutritionTargets";

const targetsValidator = v.object({
  day: v.string(),
  age: v.number(),
  bmr: v.number(),
  maintenanceCalories: v.number(),
  goalAdjustment: v.number(),
  calories: v.number(),
  proteinG: v.number(),
  carbsG: v.number(),
  fatG: v.number(),
  carbsGPerKg: v.number(),
  goalRateCapped: v.boolean(),
  calorieFloorApplied: v.boolean(),
  lowCarbs: v.boolean(),
});

/**
 * Calorie and macro targets for the signed-in user on `day` ("YYYY-MM-DD", the user's local
 * date). Null when signed out or when the user hasn't set up their profile.
 */
export const targetsForDay = query({
  args: { day: v.string() },
  returns: v.union(v.null(), targetsValidator),
  handler: async (ctx, { day }) => {
    if (!parseDay(day)) throw new ConvexError("Day must be YYYY-MM-DD.");
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", identity.subject))
      .unique();
    if (!profile) return null;
    return computeTargets(profile, day);
  },
});
