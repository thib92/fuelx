import { ConvexError, v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { query, type QueryCtx } from "./_generated/server";
import { entriesForDay, totalsOf } from "./logs";
import { bmrOn, computeTargets } from "./lib/nutritionTargets";
import { findProfile, requireDay } from "./lib/queryHelpers";
import {
  MIN_WEARABLE_STEPS,
  countedWorkouts,
  everydaySteps,
  workoutCalories,
} from "./lib/workouts";
import { findActivity, workoutsForDay } from "./workouts";

const MAX_PROGRESS_DAYS = 7;

const targetsValidator = v.object({
  day: v.string(),
  age: v.number(),
  bmr: v.number(),
  maintenanceCalories: v.number(),
  stepsUsed: v.optional(v.number()),
  goalAdjustment: v.number(),
  workoutCalories: v.number(),
  calories: v.number(),
  proteinG: v.number(),
  carbsG: v.number(),
  fatG: v.number(),
  carbsGPerKg: v.number(),
  goalRateCapped: v.boolean(),
  calorieFloorApplied: v.boolean(),
  lowCarbs: v.boolean(),
});

async function targetsFor(
  ctx: QueryCtx,
  userId: string,
  profile: Doc<"profiles">,
  day: string,
  inProgress: boolean,
) {
  const workouts = countedWorkouts(await workoutsForDay(ctx, userId, day));
  const burned = workoutCalories(workouts, bmrOn(profile, day));
  const activity = await findActivity(ctx, userId, day);
  const wearableSteps = activity?.wearableSteps ?? 0;
  const steps =
    wearableSteps < MIN_WEARABLE_STEPS
      ? undefined
      : { everydaySteps: everydaySteps(wearableSteps, workouts), inProgress };
  return computeTargets(profile, day, steps, burned);
}

/**
 * Calorie and macro targets for the signed-in user on `day` ("YYYY-MM-DD", the user's local
 * date). Null only when signed out, and `noProfile` when the user hasn't set up their profile, so
 * the app can tell an expired session from a missing profile. `inProgress` says the day is today,
 * which the backend can't tell because it doesn't know the user's time zone.
 */
export const targetsForDay = query({
  args: { day: v.string(), inProgress: v.optional(v.boolean()) },
  returns: v.union(v.null(), v.object({ noProfile: v.literal(true) }), targetsValidator),
  handler: async (ctx, { day, inProgress = false }) => {
    requireDay(day);
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    const profile = await findProfile(ctx, identity.subject);
    if (!profile) return { noProfile: true as const };
    return targetsFor(ctx, identity.subject, profile, day, inProgress);
  },
});

/**
 * Calories eaten against the target for each of `days`, for the week strip. `today` marks the
 * day in progress, as in `targetsForDay`. Null when signed out or without a profile.
 */
export const progressForDays = query({
  args: { days: v.array(v.string()), today: v.string() },
  returns: v.union(
    v.null(),
    v.array(v.object({ day: v.string(), kcal: v.number(), targetKcal: v.number() })),
  ),
  handler: async (ctx, { days, today }) => {
    if (days.length > MAX_PROGRESS_DAYS) {
      throw new ConvexError(`Ask for at most ${MAX_PROGRESS_DAYS} days.`);
    }
    days.forEach(requireDay);
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    const userId = identity.subject;
    const profile = await findProfile(ctx, userId);
    if (!profile) return null;

    return Promise.all(
      days.map(async (day) => {
        const targets = await targetsFor(ctx, userId, profile, day, day === today);
        const { kcal } = totalsOf(await entriesForDay(ctx, userId, day));
        return { day, kcal, targetKcal: targets.calories };
      }),
    );
  },
});
