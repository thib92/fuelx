import { query } from "./_generated/server";
import { authComponent } from "./betterAuth/auth";

/** The signed-in Better Auth user, or null when signed out. */
export const getCurrentUser = query({
  args: {},
  handler: async (ctx) => {
    return await authComponent.safeGetAuthUser(ctx);
  },
});
