import { ConvexError, v } from "convex/values";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { computeTargets, parseDay } from "./lib/nutritionTargets";
import { activeKcal, countedWorkouts } from "./lib/workouts";
import { sportValidator, workoutInputFields } from "./schema";

const MAX_BATCH = 200;

const workoutView = v.object({
  _id: v.id("workouts"),
  sport: sportValidator,
  startAt: v.number(),
  durationSec: v.number(),
  activeKcal: v.number(),
  distanceM: v.optional(v.number()),
  indoor: v.optional(v.boolean()),
});

function requireDay(day: string): void {
  if (!parseDay(day)) throw new ConvexError("Day must be YYYY-MM-DD.");
}

function isCount(value: number): boolean {
  return Number.isFinite(value) && value >= 0;
}

function findWorkout(ctx: QueryCtx, userId: string, externalId: string) {
  return ctx.db
    .query("workouts")
    .withIndex("by_user_externalId", (q) => q.eq("userId", userId).eq("externalId", externalId))
    .unique();
}

export function workoutsForDay(ctx: QueryCtx, userId: string, day: string) {
  return ctx.db
    .query("workouts")
    .withIndex("by_user_day", (q) => q.eq("userId", userId).eq("day", day))
    .collect();
}

export function findActivity(ctx: QueryCtx, userId: string, day: string) {
  return ctx.db
    .query("dailyActivity")
    .withIndex("by_user_day", (q) => q.eq("userId", userId).eq("day", day))
    .unique();
}

/** A day's workouts, oldest first, and its steps. Null when signed out. */
export const forDay = query({
  args: { day: v.string() },
  returns: v.union(
    v.null(),
    v.object({ workouts: v.array(workoutView), steps: v.optional(v.number()) }),
  ),
  handler: async (ctx, { day }) => {
    requireDay(day);
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    const userId = identity.subject;

    const rows = await workoutsForDay(ctx, userId, day);
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .unique();
    const bmr = profile ? computeTargets(profile, day).bmr : undefined;

    const workouts = countedWorkouts(rows)
      .sort((a, b) => a.startAt - b.startAt)
      .map((workout) => ({
        _id: workout._id,
        sport: workout.sport,
        startAt: workout.startAt,
        durationSec: workout.durationSec,
        activeKcal: Math.round(activeKcal(workout, bmr)),
        distanceM: workout.distanceM,
        indoor: workout.indoor,
      }));
    const activity = await findActivity(ctx, userId, day);
    // The merged total can include a phone's false steps: 28,905 on a day the watch said 3,405.
    return { workouts, steps: activity?.wearableSteps ?? activity?.steps };
  },
});

/** Applies a batch from Apple Health. Safe to repeat: rows are matched by `externalId` and day. */
export const sync = mutation({
  args: {
    workouts: v.array(v.object(workoutInputFields)),
    deletedIds: v.array(v.string()),
    steps: v.array(
      v.object({
        day: v.string(),
        steps: v.number(),
        wearableSteps: v.optional(v.number()),
      }),
    ),
  },
  returns: v.null(),
  handler: async (ctx, { workouts, deletedIds, steps }) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new ConvexError("You need to be signed in.");
    const userId = identity.subject;
    if (Math.max(workouts.length, deletedIds.length, steps.length) > MAX_BATCH) {
      throw new ConvexError(`A batch can hold at most ${MAX_BATCH} items of each kind.`);
    }

    for (const workout of workouts) {
      requireDay(workout.day);
      const numbers = [workout.startAt, workout.durationSec, workout.kcal ?? 0];
      if (!numbers.every(isCount)) throw new ConvexError("Workout has invalid numbers.");
      const existing = await findWorkout(ctx, userId, workout.externalId);
      if (existing) {
        await ctx.db.replace(existing._id, { userId, ...workout });
      } else {
        await ctx.db.insert("workouts", { userId, ...workout });
      }
    }

    for (const externalId of deletedIds) {
      const existing = await findWorkout(ctx, userId, externalId);
      if (existing) await ctx.db.delete(existing._id);
    }

    for (const activity of steps) {
      requireDay(activity.day);
      if (![activity.steps, activity.wearableSteps ?? 0].every(isCount)) {
        throw new ConvexError("Steps must not be negative.");
      }
      const existing = await findActivity(ctx, userId, activity.day);
      if (existing) {
        await ctx.db.replace(existing._id, { userId, ...activity });
      } else {
        await ctx.db.insert("dailyActivity", { userId, ...activity });
      }
    }
    return null;
  },
});

/**
 * Moves a guest's workouts and steps to the account they linked. Merges, because the account may
 * already exist and have synced the same Health data.
 */
export async function transferWorkoutData(
  ctx: MutationCtx,
  fromUserId: string,
  toUserId: string,
): Promise<void> {
  const workouts = await ctx.db
    .query("workouts")
    .withIndex("by_user_day", (q) => q.eq("userId", fromUserId))
    .collect();
  for (const workout of workouts) {
    if (await findWorkout(ctx, toUserId, workout.externalId)) {
      await ctx.db.delete(workout._id);
    } else {
      await ctx.db.patch(workout._id, { userId: toUserId });
    }
  }

  const activity = await ctx.db
    .query("dailyActivity")
    .withIndex("by_user_day", (q) => q.eq("userId", fromUserId))
    .collect();
  for (const guest of activity) {
    const existing = await findActivity(ctx, toUserId, guest.day);
    if (!existing) {
      await ctx.db.patch(guest._id, { userId: toUserId });
      continue;
    }
    const wearable = [existing.wearableSteps, guest.wearableSteps].filter((n) => n !== undefined);
    await ctx.db.patch(existing._id, {
      steps: Math.max(existing.steps, guest.steps),
      ...(wearable.length > 0 && { wearableSteps: Math.max(...wearable) }),
    });
    await ctx.db.delete(guest._id);
  }
}
