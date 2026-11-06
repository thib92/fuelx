import { ConvexError, v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import {
  FAT_PERCENT_RANGE,
  GOAL_RATES,
  PROTEIN_G_PER_KG_RANGE,
  ageOn,
  parseDay,
  type NutritionProfile,
} from "./lib/nutritionTargets";
import { findProfile } from "./lib/queryHelpers";
import { transferLogData } from "./logs";
import { transferWorkoutData } from "./workouts";
import { profileInputFields } from "./schema";

const HEIGHT_CM_RANGE = { min: 100, max: 250 } as const;
const WEIGHT_KG_RANGE = { min: 30, max: 250 } as const;
const AGE_RANGE = { min: 13, max: 100 } as const;
/** Absorbs floating-point noise from client steppers (e.g. 1.2 + 0.1 * 8). */
const EPSILON = 1e-6;

const profileDoc = v.object({
  _id: v.id("profiles"),
  _creationTime: v.number(),
  userId: v.string(),
  ...profileInputFields,
});

/** The signed-in user's profile, or null if they haven't set one up. */
export const get = query({
  args: {},
  returns: v.union(v.null(), profileDoc),
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;
    return await findProfile(ctx, identity.subject);
  },
});

/** Creates or replaces the signed-in user's profile. */
export const upsert = mutation({
  args: profileInputFields,
  returns: v.null(),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new ConvexError("You need to be signed in.");

    const profile = validate(args);
    const existing = await findProfile(ctx, identity.subject);
    if (existing) {
      await ctx.db.patch(existing._id, profile);
    } else {
      await ctx.db.insert("profiles", { userId: identity.subject, ...profile });
    }
    return null;
  },
});

/**
 * Called when a guest signs in with Apple (see `onLinkAccount` in betterAuth/auth.ts).
 * The guest's profile moves to the Apple account, unless that account already has one
 * (returning user on a fresh install), in which case the existing profile wins.
 * Logged data always moves, including for guests who never set up a profile.
 */
export const transferOnLink = internalMutation({
  args: { fromUserId: v.string(), toUserId: v.string() },
  returns: v.null(),
  handler: async (ctx, { fromUserId, toUserId }) => {
    await transferLogData(ctx, fromUserId, toUserId);
    await transferWorkoutData(ctx, fromUserId, toUserId);

    const guestProfile = await findProfile(ctx, fromUserId);
    if (!guestProfile) return null;
    if (await findProfile(ctx, toUserId)) {
      await ctx.db.delete(guestProfile._id);
    } else {
      await ctx.db.patch(guestProfile._id, { userId: toUserId });
    }
    return null;
  },
});

function validate(input: NutritionProfile): NutritionProfile {
  const fail = (message: string): never => {
    throw new ConvexError(message);
  };
  const inRange = (value: number, range: { min: number; max: number }) =>
    Number.isFinite(value) &&
    value >= range.min - EPSILON &&
    value <= range.max + EPSILON;

  if (!parseDay(input.birthDate)) fail("Birth date is invalid.");
  const today = new Date().toISOString().slice(0, 10);
  if (!inRange(ageOn(input.birthDate, today), AGE_RANGE)) {
    fail(`Age must be between ${AGE_RANGE.min} and ${AGE_RANGE.max}.`);
  }
  if (!inRange(input.heightCm, HEIGHT_CM_RANGE)) {
    fail(`Height must be between ${HEIGHT_CM_RANGE.min} and ${HEIGHT_CM_RANGE.max} cm.`);
  }
  if (!inRange(input.weightKg, WEIGHT_KG_RANGE)) {
    fail(`Weight must be between ${WEIGHT_KG_RANGE.min} and ${WEIGHT_KG_RANGE.max} kg.`);
  }
  const rate = GOAL_RATES[input.goal].find(
    (allowed) => Math.abs(allowed - input.goalRateKgPerWeek) < EPSILON,
  );
  if (rate === undefined) {
    fail(`Rate must be one of ${GOAL_RATES[input.goal].join(", ")} kg/week for this goal.`);
  }
  if (!inRange(input.proteinGPerKg, PROTEIN_G_PER_KG_RANGE)) {
    fail(
      `Protein must be between ${PROTEIN_G_PER_KG_RANGE.min} and ${PROTEIN_G_PER_KG_RANGE.max} g/kg.`,
    );
  }
  if (!inRange(input.fatPercent, FAT_PERCENT_RANGE)) {
    fail(`Fat must be between ${FAT_PERCENT_RANGE.min}% and ${FAT_PERCENT_RANGE.max}%.`);
  }

  return {
    ...input,
    goalRateKgPerWeek: rate!,
    proteinGPerKg: Math.round(input.proteinGPerKg * 10) / 10,
    fatPercent: Math.round(input.fatPercent),
  };
}

