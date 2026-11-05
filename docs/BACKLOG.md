# Backlog

Ideas and follow-ups collected while setting up auth and the day view (2026-10-31).
Nothing here is scheduled; it's a list to pick from.

## Auth (required before shipping)

- **Migrate guest data on upgrade.** `onLinkAccount` in `convex/betterAuth/auth.ts` moves the
  guest's profile (`profile:transferOnLink`). Every new user-owned table needs the same, and it
  must *merge*: it also runs when the Apple account already exists (returning user, fresh install).
- **Account deletion (App Store Guideline 5.1.1(v)).** Apps that create accounts must offer
  in-app deletion; with Sign in with Apple that includes revoking Apple's tokens.
- **Clean up orphaned guests.** Guests who uninstall leave unused users behind; add a Convex cron
  that deletes stale anonymous users.
- **Per-environment URLs.** `fuelx/ConvexClient.swift` hardcodes the dev deployment URLs; drive
  them from the build configuration before a production build.

## Housekeeping

- The `SITE_URL` env var on the Convex dev deployment is unused (`npx convex env remove SITE_URL`).
- x86_64 simulator builds don't link (ConvexMobile ships an arm64-only simulator slice). Fine on
  Apple Silicon; matters only for Intel Macs or CI.

## Day view: navigation alternatives

Current: horizontal swipe between days + week strip + calendar jump + "Today" button.

| Option | Pros | Cons |
|---|---|---|
| Chevron header (‹ Today ›) | Simplest, most discoverable | Slow to go back weeks; could complement swipe |
| Vertical feed of days | Good for scanning trends | Less focus on a single day |
| Swipeable week strip (Fitness / Calendar style) | Jump week by week without the calendar | More work; natural next step |

## Product ideas

1. **Daily target.** Net calories mean little without a target or resting energy. "Burned"
   currently counts workouts only; add resting energy (HealthKit or an estimate) and a target,
   shown as a ring or progress bar.
2. **Carbs per hour for fuel.** Endurance athletes plan fueling in g carbs/h (~60–90+ g/h) more
   than kcal. Add carbs to `FuelItem` and show g/h on each workout.
3. **Week strip indicators.** A dot or mini bar per day for "logged" or "on target".
4. **Quick add.** Buttons to log a meal, a workout or fuel. Later, import workouts and calories
   burned from HealthKit.
5. **Timeline view.** Interleave meals and workouts by time so eating around training is visible.

## Nutrition targets

Current (2026-11-05): Mifflin-St Jeor BMR x non-exercise activity factor (sedentary 1.2 /
light 1.35 / moderate 1.5; workouts ignored for now) ± goal (rate x 7,700 / 7 kcal/day, loss capped at 1% body weight/week, never below
BMR); protein fixed g/kg (default 1.6), fat fixed % of calories (default 25%), carbs = rest.
Logic: `convex/lib/nutritionTargets.ts`.

- **Count workouts.** Once workouts are connected, add each day's logged/planned workout active
  kcal on top of maintenance (the activity factors already exclude exercise, so nothing is
  counted twice). Extra calories then flow into carbs automatically.
- **Carbs periodized by training load** (ACSM 2016: 3–5 / 5–7 / 6–10 / 8–12 g/kg) and per-workout
  fuel targets (Burke 2011 / Jeukendrup 2014: ~1 h small amounts, 30–60 g/h, >2.5 h up to 90 g/h).
- **Fuel for tomorrow**: raise carbs the day before a planned key session.
- **Macros per meal/fuel item**, so the day view can show protein/carbs/fat eaten vs. target.
- **Imperial units** (lb, ft/in) in the profile form; the backend stays metric.

## Data layer notes

- **Key days by a local date string** (`"2026-10-31"` in the user's time zone), not timestamps,
  so travel and DST don't move entries to the wrong day. Each visible `DayPage` can subscribe
  to e.g. `logs:forDay({ day })`, replacing `MockDayLogs.log(for:)`.
- **Midnight rollover.** `HomeView` computes "today" at launch; handle the day changing while
  the app is open (`scenePhase` / significant time change).
