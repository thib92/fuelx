import { ConvexError } from "convex/values";
import type { QueryCtx } from "../_generated/server";
import { parseDay } from "./nutritionTargets";

export function requireDay(day: string): void {
  if (!parseDay(day)) throw new ConvexError("Day must be YYYY-MM-DD.");
}

export function findProfile(ctx: QueryCtx, userId: string) {
  return ctx.db
    .query("profiles")
    .withIndex("by_userId", (q) => q.eq("userId", userId))
    .unique();
}
