import { ConvexError, v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { mutation, query } from "./_generated/server";
import { isInRange } from "./lib/foodQuality";
import { normalizeTerms, rankFoods, searchTextFor } from "./lib/foodSearch";
import {
  foodSourceValidator,
  importDocValidator,
  per100gValidator,
  type ImportDoc,
} from "./schema";

/** Prefix matches crowd the top results, so ranking needs a wide net to find exact ones. */
const SEARCH_FETCH_LIMIT = 200;
/** Generic foods are searched separately, or 620k products would crowd them out. */
const GENERIC_FETCH_LIMIT = 50;
const OWN_FOODS_FETCH_LIMIT = 50;
const SEARCH_RESULT_LIMIT = 25;
const RECENTS_FOR_RANKING = 200;
const MAX_IMPORT_BATCH = 500;
const MAX_NAME_LENGTH = 120;
const MAX_SERVING_G = 5000;

const foodResult = v.object({
  _id: v.id("foods"),
  name: v.string(),
  brand: v.optional(v.string()),
  source: foodSourceValidator,
  per100g: per100gValidator,
  servingG: v.optional(v.number()),
});

function toResult(food: Doc<"foods">) {
  return {
    _id: food._id,
    name: food.name,
    brand: food.brand,
    source: food.source,
    per100g: food.per100g,
    servingG: food.servingG,
  };
}

/** Public foods plus the caller's custom foods, best match first. */
export const search = query({
  args: { query: v.string() },
  returns: v.array(foodResult),
  handler: async (ctx, { query: rawQuery }) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];
    const userId = identity.subject;

    const terms = normalizeTerms(rawQuery);
    if (terms.length === 0) return [];
    const searchQuery = terms.join(" ");

    const [publicFoods, genericFoods, ownFoods, recents] = await Promise.all([
      ctx.db
        .query("foods")
        .withSearchIndex("search_text", (q) =>
          q.search("searchText", searchQuery).eq("ownerId", undefined),
        )
        .take(SEARCH_FETCH_LIMIT),
      ctx.db
        .query("foods")
        .withSearchIndex("search_text", (q) =>
          q.search("searchText", searchQuery).eq("source", "ciqual"),
        )
        .take(GENERIC_FETCH_LIMIT),
      ctx.db
        .query("foods")
        .withSearchIndex("search_text", (q) =>
          q.search("searchText", searchQuery).eq("ownerId", userId),
        )
        .take(OWN_FOODS_FETCH_LIMIT),
      ctx.db
        .query("recentFoods")
        .withIndex("by_user_lastUsed", (q) => q.eq("userId", userId))
        .order("desc")
        .take(RECENTS_FOR_RANKING),
    ]);

    const recentIds = new Set<string>(recents.map((recent) => recent.foodId));
    const candidates = new Map(
      [...ownFoods, ...genericFoods, ...publicFoods].map((food) => [food._id, food]),
    );
    return rankFoods([...candidates.values()], terms, recentIds, rawQuery)
      .slice(0, SEARCH_RESULT_LIMIT)
      .map(toResult);
  },
});

/** Creates a food only the caller can see. */
export const createCustom = mutation({
  args: {
    name: v.string(),
    brand: v.optional(v.string()),
    per100g: per100gValidator,
    servingG: v.optional(v.number()),
  },
  returns: v.id("foods"),
  handler: async (ctx, { name: rawName, brand: rawBrand, per100g, servingG }) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new ConvexError("You need to be signed in.");

    const name = rawName.trim();
    const brand = rawBrand?.trim() || undefined;
    if (name.length < 2) throw new ConvexError("Enter a name.");
    if (name.length > MAX_NAME_LENGTH || (brand?.length ?? 0) > MAX_NAME_LENGTH) {
      throw new ConvexError(`Names can be up to ${MAX_NAME_LENGTH} characters.`);
    }
    // Range only: the calorie check would block drinks, whose energy comes from alcohol.
    if (!isInRange(per100g)) throw new ConvexError("Those values don't add up.");
    if (servingG !== undefined && !(servingG > 0 && servingG <= MAX_SERVING_G)) {
      throw new ConvexError(`Serving size must be between 0 and ${MAX_SERVING_G} g.`);
    }

    return await ctx.db.insert("foods", {
      source: "custom",
      sourceId: crypto.randomUUID(),
      ownerId: identity.subject,
      name,
      brand,
      searchText: searchTextFor({ name, brand }),
      per100g,
      servingG,
    });
  },
});

/** Compares two flat objects, treating undefined fields as absent. */
function sameFields(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const defined = (fields: Record<string, unknown>) =>
    Object.entries(fields).filter(([, value]) => value !== undefined);
  const entries = defined(a);
  return (
    entries.length === defined(b).length &&
    entries.every(([key, value]) => b[key] === value)
  );
}

function isUnchanged(existing: Doc<"foods">, doc: ImportDoc): boolean {
  const { per100g, ...fields } = doc;
  const { _id, _creationTime, per100g: existingPer100g, ...existingFields } = existing;
  return sameFields(fields, existingFields) && sameFields(per100g, existingPer100g);
}

/**
 * Upserts CIQUAL and OFF foods from scripts/foods/upload.ts. Public so the script can batch
 * without a deploy key, and guarded by FOODS_IMPORT_SECRET. The validator only accepts those two
 * sources, so "label" and "custom" foods are never touched.
 */
export const importBatch = mutation({
  args: { secret: v.string(), docs: v.array(importDocValidator) },
  returns: v.object({ inserted: v.number(), updated: v.number(), unchanged: v.number() }),
  handler: async (ctx, { secret, docs }) => {
    const expected = process.env.FOODS_IMPORT_SECRET;
    if (!expected || secret !== expected) throw new ConvexError("Not allowed.");
    if (docs.length > MAX_IMPORT_BATCH) {
      throw new ConvexError(`Send at most ${MAX_IMPORT_BATCH} docs at a time.`);
    }

    const counts = { inserted: 0, updated: 0, unchanged: 0 };
    for (const doc of docs) {
      const existing = await ctx.db
        .query("foods")
        .withIndex("by_source_sourceId", (q) =>
          q.eq("source", doc.source).eq("sourceId", doc.sourceId),
        )
        .unique();
      if (!existing) {
        await ctx.db.insert("foods", doc);
        counts.inserted += 1;
      } else if (isUnchanged(existing, doc)) {
        counts.unchanged += 1;
      } else {
        await ctx.db.replace(existing._id, doc);
        counts.updated += 1;
      }
    }
    return counts;
  },
});
