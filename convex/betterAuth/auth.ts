import { createClient } from "@convex-dev/better-auth";
import { convex } from "@convex-dev/better-auth/plugins";
import type { GenericCtx } from "@convex-dev/better-auth/utils";
import type { BetterAuthOptions } from "better-auth";
import { betterAuth } from "better-auth";
import { anonymous } from "better-auth/plugins";
import { components, internal } from "../_generated/api";
import type { DataModel } from "../_generated/dataModel";
import authConfig from "../auth.config";
import schema from "./schema";

/** Apple puts this in the `aud` claim of identity tokens issued to the iOS app. */
const IOS_BUNDLE_ID = "dev.thenry.fuelx";

export const authComponent = createClient<DataModel, typeof schema>(
  components.betterAuth,
  {
    local: { schema },
    verbose: false,
  },
);

export const createAuthOptions = (ctx: GenericCtx<DataModel>) => {
  return {
    appName: "Fuelx",
    // iOS-only: the app talks to Better Auth directly on the Convex HTTP
    // actions domain (https://<deployment>.convex.site), so that is the base
    // URL. CONVEX_SITE_URL is a built-in Convex env var. If a web frontend is
    // added later, switch this to that frontend's URL (see the Better Auth
    // Convex docs).
    baseURL: process.env.CONVEX_SITE_URL,
    secret: process.env.BETTER_AUTH_SECRET,
    database: authComponent.adapter(ctx),
    session: {
      // Mobile sessions: valid for a year, extended at most once a day while
      // the app is used. The default (7 days) would strand guests, whose
      // accounts can't be recovered once their session lapses.
      expiresIn: 60 * 60 * 24 * 365,
      updateAge: 60 * 60 * 24,
    },
    socialProviders: {
      // Native Sign in with Apple only: the app sends Apple's identity token
      // to /sign-in/social and Better Auth verifies it against Apple's public
      // keys. No client secret is configured, so the web redirect flow is
      // unavailable (it needs a Services ID + signing key).
      apple: {
        clientId: IOS_BUNDLE_ID,
        appBundleIdentifier: IOS_BUNDLE_ID,
      },
    },
    plugins: [
      // Guests get a real user + session via /sign-in/anonymous. When a guest
      // signs in with Apple (sending their guest session as the bearer
      // token), the guest user is deleted after `onLinkAccount` runs.
      anonymous({
        onLinkAccount: async ({ anonymousUser, newUser }) => {
          // Move the guest's app data to the Apple account. This also runs
          // when the Apple account already existed (returning user on a
          // fresh install), so each transfer must merge, not overwrite.
          // Sign-in runs in an HTTP action, which can run mutations.
          if (!("runMutation" in ctx)) return;
          await ctx.runMutation(internal.profile.transferOnLink, {
            fromUserId: anonymousUser.user.id,
            toUserId: newUser.user.id,
          });
        },
      }),
      // `convex()` also installs Better Auth's bearer plugin, which lets the
      // iOS app authenticate with `Authorization: Bearer <session token>`
      // instead of cookies.
      convex({ authConfig }),
    ],
  } satisfies BetterAuthOptions;
};

export const options = createAuthOptions({} as GenericCtx<DataModel>);

export const createAuth = (ctx: GenericCtx<DataModel>) => {
  return betterAuth(createAuthOptions(ctx));
};
