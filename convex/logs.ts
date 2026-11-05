import { ConvexError, v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { entryNutrition, roundNutrition, sumNutrition, type Nutrition } from "./lib/logMath";
import { requireDay } from "./lib/queryHelpers";
import { foodSourceValidator, mealValidator, per100gValidator, type MealName } from "./schema";

const MAX_GRAMS = 5000;
const DEFAULT_RECENTS = 30;
const MAX_RECENTS = 100;
const MEALS: MealName[] = ["breakfast", "lunch", "dinner", "snack"];

const totalsValidator = v.object({
  kcal: v.number(),
  proteinG: v.number(),
  carbsG: v.number(),
  fatG: v.number(),
});

const entryView = v.object({
  _id: v.id("logEntries"),
  meal: mealValidator,
  name: v.string(),
  brand: v.optional(v.string()),
  grams: v.number(),
  per100g: per100gValidator,
  kcal: v.number(),
  proteinG: v.number(),
  carbsG: v.number(),
  fatG: v.number(),
  estimated: v.boolean(),
  foodId: v.optional(v.id("foods")),
});

async function requireUserId(ctx: QueryCtx): Promise<string> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new ConvexError("You need to be signed in.");
  return identity.subject;
}

function requireGrams(grams: number): void {
  if (!(Number.isFinite(grams) && grams > 0 && grams <= MAX_GRAMS)) {
    throw new ConvexError(`Grams must be between 0 and ${MAX_GRAMS}.`);
  }
}

async function requireOwnEntry(ctx: QueryCtx, id: Id<"logEntries">, userId: string) {
  const entry = await ctx.db.get(id);
  if (!entry || entry.userId !== userId) throw new ConvexError("Entry not found.");
  return entry;
}

export function entriesForDay(ctx: QueryCtx, userId: string, day: string) {
  return ctx.db
    .query("logEntries")
    .withIndex("by_user_day", (q) => q.eq("userId", userId).eq("day", day))
    .collect();
}

/** Remembers that the user just logged this food, for recents and search ranking. */
async function touchRecent(
  ctx: MutationCtx,
  userId: string,
  foodId: Id<"foods">,
  grams: number,
): Promise<void> {
  const lastUsedAt = Date.now();
  const recent = await ctx.db
    .query("recentFoods")
    .withIndex("by_user_food", (q) => q.eq("userId", userId).eq("foodId", foodId))
    .unique();
  if (recent) {
    await ctx.db.patch(recent._id, {
      lastUsedAt,
      lastGrams: grams,
      useCount: recent.useCount + 1,
    });
  } else {
    await ctx.db.insert("recentFoods", {
      userId,
      foodId,
      lastUsedAt,
      lastGrams: grams,
      useCount: 1,
    });
  }
}

function nutritionOf(entry: Doc<"logEntries">): Nutrition {
  return entryNutrition(entry.grams, entry.per100g);
}

export function totalsOf(entries: Doc<"logEntries">[]): Nutrition {
  return roundNutrition(sumNutrition(entries.map(nutritionOf)));
}

/** A day's entries, oldest first, with totals. Null when signed out. */
export const forDay = query({
  args: { day: v.string() },
  returns: v.union(
    v.null(),
    v.object({
      entries: v.array(entryView),
      totals: totalsValidator,
      mealTotals: v.object({
        breakfast: totalsValidator,
        lunch: totalsValidator,
        dinner: totalsValidator,
        snack: totalsValidator,
      }),
    }),
  ),
  handler: async (ctx, { day }) => {
    requireDay(day);
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;

    const entries = await entriesForDay(ctx, identity.subject, day);
    const forMeal = (meal: MealName) => totalsOf(entries.filter((entry) => entry.meal === meal));
    return {
      entries: entries.map((entry) => ({
        _id: entry._id,
        meal: entry.meal,
        name: entry.name,
        brand: entry.brand,
        grams: entry.grams,
        per100g: entry.per100g,
        estimated: entry.estimated,
        foodId: entry.foodId,
        ...roundNutrition(nutritionOf(entry)),
      })),
      totals: totalsOf(entries),
      mealTotals: {
        breakfast: forMeal("breakfast"),
        lunch: forMeal("lunch"),
        dinner: forMeal("dinner"),
        snack: forMeal("snack"),
      },
    };
  },
});

/** Logs an amount of a food, copying its current nutrition onto the entry. */
export const add = mutation({
  args: {
    day: v.string(),
    meal: mealValidator,
    foodId: v.id("foods"),
    grams: v.number(),
    origin: v.union(v.literal("search"), v.literal("recent"), v.literal("barcode")),
  },
  returns: v.id("logEntries"),
  handler: async (ctx, { day, meal, foodId, grams, origin }) => {
    const userId = await requireUserId(ctx);
    requireDay(day);
    requireGrams(grams);

    const food = await ctx.db.get(foodId);
    if (!food || (food.ownerId !== undefined && food.ownerId !== userId)) {
      throw new ConvexError("Food not found.");
    }

    const id = await ctx.db.insert("logEntries", {
      userId,
      day,
      meal,
      loggedAt: Date.now(),
      foodId,
      name: food.name,
      brand: food.brand,
      grams,
      per100g: food.per100g,
      origin,
      estimated: false,
    });
    await touchRecent(ctx, userId, foodId, grams);
    return id;
  },
});

export const update = mutation({
  args: {
    id: v.id("logEntries"),
    grams: v.optional(v.number()),
    meal: v.optional(mealValidator),
  },
  returns: v.null(),
  handler: async (ctx, { id, grams, meal }) => {
    const userId = await requireUserId(ctx);
    await requireOwnEntry(ctx, id, userId);
    if (grams !== undefined) requireGrams(grams);
    // `patch` deletes fields set to undefined, so only pass the ones that changed.
    await ctx.db.patch(id, {
      ...(grams !== undefined && { grams }),
      ...(meal !== undefined && { meal }),
    });
    return null;
  },
});

export const remove = mutation({
  args: { id: v.id("logEntries") },
  returns: v.null(),
  handler: async (ctx, { id }) => {
    const userId = await requireUserId(ctx);
    await requireOwnEntry(ctx, id, userId);
    await ctx.db.delete(id);
    return null;
  },
});

/** Copies one meal to another day and returns how many entries were copied. */
export const copyMeal = mutation({
  args: { fromDay: v.string(), toDay: v.string(), meal: mealValidator },
  returns: v.number(),
  handler: async (ctx, { fromDay, toDay, meal }) => {
    const userId = await requireUserId(ctx);
    requireDay(fromDay);
    requireDay(toDay);
    if (fromDay === toDay) throw new ConvexError("Pick a different day to copy from.");

    const source = (await entriesForDay(ctx, userId, fromDay)).filter(
      (entry) => entry.meal === meal,
    );
    const loggedAt = Date.now();
    for (const { _id, _creationTime, ...entry } of source) {
      await ctx.db.insert("logEntries", { ...entry, day: toDay, loggedAt, origin: "copy" });
      if (entry.foodId) await touchRecent(ctx, userId, entry.foodId, entry.grams);
    }
    return source.length;
  },
});

/** The caller's most recently logged foods, newest first. */
export const recents = query({
  args: { limit: v.optional(v.number()) },
  returns: v.array(
    v.object({
      foodId: v.id("foods"),
      name: v.string(),
      brand: v.optional(v.string()),
      source: foodSourceValidator,
      per100g: per100gValidator,
      servingG: v.optional(v.number()),
      lastGrams: v.number(),
    }),
  ),
  handler: async (ctx, { limit = DEFAULT_RECENTS }) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const recentFoods = await ctx.db
      .query("recentFoods")
      .withIndex("by_user_lastUsed", (q) => q.eq("userId", identity.subject))
      .order("desc")
      .take(Math.min(Math.max(1, Math.floor(limit)), MAX_RECENTS));

    const results = await Promise.all(
      recentFoods.map(async ({ foodId, lastGrams }) => {
        const food = await ctx.db.get(foodId);
        return food
          ? {
              foodId,
              name: food.name,
              brand: food.brand,
              source: food.source,
              per100g: food.per100g,
              servingG: food.servingG,
              lastGrams,
            }
          : null;
      }),
    );
    return results.filter((result) => result !== null);
  },
});

async function transferRecents(ctx: MutationCtx, fromUserId: string, toUserId: string) {
  const guestRecents = await ctx.db
    .query("recentFoods")
    .withIndex("by_user_food", (q) => q.eq("userId", fromUserId))
    .collect();
  for (const guest of guestRecents) {
    const existing = await ctx.db
      .query("recentFoods")
      .withIndex("by_user_food", (q) => q.eq("userId", toUserId).eq("foodId", guest.foodId))
      .unique();
    if (!existing) {
      await ctx.db.patch(guest._id, { userId: toUserId });
      continue;
    }
    const latest = guest.lastUsedAt > existing.lastUsedAt ? guest : existing;
    await ctx.db.patch(existing._id, {
      lastUsedAt: latest.lastUsedAt,
      lastGrams: latest.lastGrams,
      useCount: existing.useCount + guest.useCount,
    });
    await ctx.db.delete(guest._id);
  }
}

/**
 * Moves a guest's log data to the account they linked. Merges, because the account may already
 * exist (returning user on a fresh install).
 */
export async function transferLogData(
  ctx: MutationCtx,
  fromUserId: string,
  toUserId: string,
): Promise<void> {
  const entries = await ctx.db
    .query("logEntries")
    .withIndex("by_user_day", (q) => q.eq("userId", fromUserId))
    .collect();
  for (const entry of entries) {
    await ctx.db.patch(entry._id, { userId: toUserId });
  }

  await transferRecents(ctx, fromUserId, toUserId);

  // Custom foods are few, so filtering them avoids an index across every food.
  const customFoods = await ctx.db
    .query("foods")
    .withIndex("by_source_sourceId", (q) => q.eq("source", "custom"))
    .filter((q) => q.eq(q.field("ownerId"), fromUserId))
    .collect();
  for (const food of customFoods) {
    await ctx.db.patch(food._id, { ownerId: toUserId });
  }
}
