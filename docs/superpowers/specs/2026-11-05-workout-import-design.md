# Workout import from Apple Health

Replaces `MockDayLogs` with the user's real workouts and steps. Planned workouts from Intervals.icu
are a later piece; so is adding workout calories to the daily targets.

## Why Apple Health

Garmin Connect, Apple Watch and other apps all write to it, it needs no partner approval, and it
works for friends with any device. Intervals.icu may lose Garmin data through its API, and Strava's
terms cap caching at 7 days and bar use in AI applications.

## What Garmin writes

From a report of 38 real workouts (2026-11-05):

- **Multisport:** a parent "Other" workout plus one workout per leg, including transitions. On the
  11/10 triathlon the parent's active kcal (5,047) equals the legs' active (4,468) plus their basal
  (579), and its distance equals theirs.
- **Calories:** a workout with a basal statistic has active kcal net of resting energy.
- **Third-party uploads:** Rouvy rides pushed through Garmin Connect have no basal statistic. Connect
  shows the same 774 kcal as Health, so nothing was taken off. The figure is Rouvy's own estimate.
- **Titles:** none, and no device.
- **Energy samples:** summing them over a workout's time window gives nonsense. Only the workout's
  own statistics are usable.

## Data

`workouts`, one row per Health workout, unique on `userId` + `externalId` (the HealthKit UUID):
`day`, `sport`, `startAt`, `durationSec`, `sourceBundleId`, and optional `kcal`, `basalKcal`,
`distanceM`, `indoor`.

`dailyActivity`, one row per day: `steps` from every source, and `wearableSteps`, which leaves out
the iPhone. Targets use `wearableSteps`, and the day page shows it when there is one: Health's merged
total can include a phone's false steps (28,905 on the 01/11 ride, when the watch said 3,405). Garmin
writes steps late, so today usually has none yet and falls back to the activity level.

Rows store what Health said. The rules below run when reading, so changing a rule needs no re-import.

## Rules (`convex/lib/workouts.ts`)

1. **Duplicates are hidden.** Two devices can record one session: the 31 May and 6 Sep races each
   have two bike legs. Same-sport workouts overlapping by 80% of the longer one are one session, and
   the higher calories win. This runs first, because a duplicate can look like a leg.
2. **Multisport parents are hidden.** A workout that spans two or more shorter workouts from the same
   app is a parent. Requiring two keeps a lone overlap from hiding a real workout.
3. **Active kcal.** With a basal statistic, `kcal` is used as is. A Garmin Connect workout without one
   has `durationMin × BMR / 1440` taken off, using the profile's BMR. Without a profile, or from any
   other app, `kcal` is used as is.

## Targets from steps

Everyday activity comes from steps when a watch provides them:

`maintenance = BMR × 1.2 + max(0, everyday steps − 2,500) × 0.0004 × kg`

- **Everyday steps** are `wearableSteps` minus workouts: 165 steps/min of running, 1.3 steps/m of
  walking or hiking. The real data needs this: the median is about 6,650 steps on days without a run
  and 13,800 on run days.
- **The activity factor** is the fallback, when a day has under 1,000 wearable steps (phone only, or
  the watch wasn't worn).
- **Today** uses the higher of steps and the activity factor, so a morning's steps don't start the
  target low. The app says which day is today, because the backend doesn't know the time zone.

1.2 is the sedentary factor and 2,500 steps is taken as what it already includes. 0.0004 kcal/kg/step
is the net cost of walking (3.5 METs at 4.8 km/h, 1,300 steps/km). All three are estimates.

## Sync (`fuelx/Health/HealthSync.swift`)

- The user connects from the day page or Account, which shows the Health permission sheet.
- `HKAnchoredObjectQuery` returns new and deleted workouts since the last anchor. The first sync
  covers the last 365 days. The anchor is saved per user and only after the upload succeeds, so a
  failed upload retries and switching accounts re-sends everything; uploads are idempotent.
- Steps for the last 7 days are sent on every sync, because they change through the day. The first
  sync sends 365 days.
- Uploads go in batches of 100 to `workouts:sync`.
- Syncs run when the app becomes active, and from an `HKObserverQuery` with background delivery,
  with a 20 s limit so HealthKit always gets its completion call.

## Guest upgrade

`transferWorkoutData` merges by `externalId` and by day, like the other user-owned tables.

## Removed

`MockDayLogs`, and workout fuel, which only ever existed there. Gels stay ordinary logged foods.

## Open questions

Background delivery and sync delay can only be checked on the next real workout. Apple Watch data is
untested. HealthKit UUIDs are assumed stable; if Garmin rewrites a workout, the anchored query should
report a delete plus an add, which the sync handles.
