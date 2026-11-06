import { ConvexError } from "convex/values";

/** Mirrors `UserError` in fuelx/Nutrition/NutritionModels.swift, which words these for the user. */
export type UserErrorCode =
  | "notSignedIn"
  | "nameRequired"
  | "nameTooLong"
  | "invalidNutrition"
  | "invalidServing"
  | "invalidGrams"
  | "entryNotFound"
  | "foodNotFound"
  | "foodNotSaved"
  | "invalidHeight"
  | "invalidWeight";

/**
 * An error people can run into, which the app translates from `code`. `message` is the English,
 * for logs and for an app too old to know the code. Errors only a bug can cause stay plain strings.
 */
export function userError(
  code: UserErrorCode,
  message: string,
  limits?: { min?: number; max: number },
) {
  return new ConvexError({ code, message, ...limits });
}

export function notSignedIn() {
  return userError("notSignedIn", "You need to be signed in.");
}
