/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as auth from "../auth.js";
import type * as foods from "../foods.js";
import type * as http from "../http.js";
import type * as lib_foodQuality from "../lib/foodQuality.js";
import type * as lib_foodSearch from "../lib/foodSearch.js";
import type * as lib_logMath from "../lib/logMath.js";
import type * as lib_nutritionTargets from "../lib/nutritionTargets.js";
import type * as lib_offProduct from "../lib/offProduct.js";
import type * as lib_workouts from "../lib/workouts.js";
import type * as logs from "../logs.js";
import type * as nutrition from "../nutrition.js";
import type * as profile from "../profile.js";
import type * as workouts from "../workouts.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  auth: typeof auth;
  foods: typeof foods;
  http: typeof http;
  "lib/foodQuality": typeof lib_foodQuality;
  "lib/foodSearch": typeof lib_foodSearch;
  "lib/logMath": typeof lib_logMath;
  "lib/nutritionTargets": typeof lib_nutritionTargets;
  "lib/offProduct": typeof lib_offProduct;
  "lib/workouts": typeof lib_workouts;
  logs: typeof logs;
  nutrition: typeof nutrition;
  profile: typeof profile;
  workouts: typeof workouts;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {
  betterAuth: import("../betterAuth/_generated/component.js").ComponentApi<"betterAuth">;
};
