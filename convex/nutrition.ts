import { ConvexError, v } from "convex/values";
import { query } from "./_generated/server";
import { computeTargets, parseDay } from "./lib/nutritionTargets";
import { MIN_WEARABLE_STEPS, countedWorkouts, everydaySteps } from "./lib/workouts";
import { findActivity, workoutsForDay } from "./workouts";

const targetsValidator = v.object({
  day: v.string(),
  age: v.number(),
  bmr: v.number(),
  maintenanceCalories: v.number(),
  stepsUsed: v.optional(v.number()),
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
 * date). Null when signed out or when the user hasn't set up their profile. `inProgress` says
 * the day is today, which the backend can't tell because it doesn't know the user's time zone.
 */
export const targetsForDay = query({
  args: { day: v.string(), inProgress: v.optional(v.boolean()) },
  returns: v.union(v.null(), targetsValidator),
  handler: async (ctx, { day, inProgress = false }) => {
    if (!parseDay(day)) throw new ConvexError("Day must be YYYY-MM-DD.");
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", identity.subject))
      .unique();
    if (!profile) return null;

    const activity = await findActivity(ctx, identity.subject, day);
    const wearableSteps = activity?.wearableSteps ?? 0;
    if (wearableSteps < MIN_WEARABLE_STEPS) return computeTargets(profile, day);

    const workouts = countedWorkouts(await workoutsForDay(ctx, identity.subject, day));
    return computeTargets(profile, day, {
      everydaySteps: everydaySteps(wearableSteps, workouts),
      inProgress,
    });
  },
});
