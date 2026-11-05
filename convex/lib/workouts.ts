/**
 * How imported workouts are read. Rows keep what Apple Health said, and these rules run on top, so
 * changing a rule needs no re-import. Findings: docs/superpowers/specs/2026-11-05-workout-import-design.md
 */

export const GARMIN_CONNECT_BUNDLE_ID = "com.garmin.connect.mobile";

const MS_PER_SECOND = 1000;
const MINUTES_PER_DAY = 1440;
/** Parent and leg times are rounded differently, so "spans" allows this much slack. */
const SPAN_TOLERANCE_MS = 60_000;
/** One overlap could be chance; a multisport activity has at least two legs. */
const MIN_LEGS = 2;
/** Same-sport workouts sharing this much of the longer one are the same session, recorded twice. */
const DUPLICATE_OVERLAP = 0.8;
/** Below this the watch probably wasn't worn, so the day's steps say little. */
export const MIN_WEARABLE_STEPS = 1000;
const RUN_STEPS_PER_MINUTE = 165;
const WALK_STEPS_PER_METER = 1.3;

interface WorkoutSpan {
  sourceBundleId: string;
  startAt: number;
  durationSec: number;
}

interface WorkoutActivity {
  sport: string;
  durationSec: number;
  distanceM?: number;
}

interface WorkoutEnergy {
  sourceBundleId: string;
  durationSec: number;
  kcal?: number;
  basalKcal?: number;
}

function endOf(workout: WorkoutSpan): number {
  return workout.startAt + workout.durationSec * MS_PER_SECOND;
}

function spans(outer: WorkoutSpan, inner: WorkoutSpan): boolean {
  return (
    outer.sourceBundleId === inner.sourceBundleId &&
    outer.durationSec > inner.durationSec &&
    outer.startAt <= inner.startAt + SPAN_TOLERANCE_MS &&
    endOf(outer) >= endOf(inner) - SPAN_TOLERANCE_MS
  );
}

function isSameSession(a: WorkoutSpan & { sport: string }, b: WorkoutSpan & { sport: string }): boolean {
  if (a.sport !== b.sport) return false;
  const overlapMs = Math.min(endOf(a), endOf(b)) - Math.max(a.startAt, b.startAt);
  const longestMs = Math.max(a.durationSec, b.durationSec) * MS_PER_SECOND;
  return overlapMs >= longestMs * DUPLICATE_OVERLAP;
}

/**
 * Keeps one copy of a session recorded by two devices, such as a watch and a bike computer, or a
 * Garmin and an Apple Watch. Nothing says which is more accurate, so the highest calories win.
 */
export function withoutDuplicates<T extends WorkoutSpan & { sport: string; kcal?: number }>(
  workouts: T[],
): T[] {
  const kept: T[] = [];
  const byKcal = [...workouts].sort((a, b) => (b.kcal ?? 0) - (a.kcal ?? 0));
  for (const workout of byKcal) {
    if (!kept.some((other) => isSameSession(workout, other))) kept.push(workout);
  }
  return workouts.filter((workout) => kept.includes(workout));
}

/**
 * Drops multisport parents. Garmin writes a parent workout that repeats its legs' totals, so
 * keeping both would count the activity twice.
 */
export function withoutMultisportParents<T extends WorkoutSpan>(workouts: T[]): T[] {
  return workouts.filter(
    (workout) => workouts.filter((other) => spans(workout, other)).length < MIN_LEGS,
  );
}

/**
 * Calories burned by the workout itself. Garmin takes resting energy off its own activities and
 * records it as basal, but not off activities other apps upload to it (Rouvy, for example), so
 * those get an estimate from the user's BMR.
 */
export function activeKcal(workout: WorkoutEnergy, bmr: number | undefined): number {
  const kcal = workout.kcal ?? 0;
  const isUncorrected =
    workout.sourceBundleId === GARMIN_CONNECT_BUNDLE_ID && workout.basalKcal === undefined;
  if (!isUncorrected || bmr === undefined) return kcal;
  const restingKcal = (workout.durationSec / 60) * (bmr / MINUTES_PER_DAY);
  return Math.max(0, kcal - restingKcal);
}

/** Whole calories per workout, so the total matches the rows the app shows. */
export function workoutCalories(workouts: WorkoutEnergy[], bmr: number | undefined): number {
  return workouts.reduce((sum, workout) => sum + Math.round(activeKcal(workout, bmr)), 0);
}

/** The workouts that count, in the order given. Duplicates go first: they can look like legs. */
export function countedWorkouts<T extends WorkoutSpan & { sport: string; kcal?: number }>(
  workouts: T[],
): T[] {
  return withoutMultisportParents(withoutDuplicates(workouts));
}

/** Estimated steps a workout added to the day's count. Other sports add too few to matter. */
function stepsDuring(workout: WorkoutActivity): number {
  if (workout.sport === "run") return (workout.durationSec / 60) * RUN_STEPS_PER_MINUTE;
  if (workout.sport === "walk" || workout.sport === "hike") {
    return (workout.distanceM ?? 0) * WALK_STEPS_PER_METER;
  }
  return 0;
}

/** The day's steps without workouts, which are counted on their own. */
export function everydaySteps(steps: number, workouts: WorkoutActivity[]): number {
  return Math.max(0, steps - workouts.reduce((sum, workout) => sum + stepsDuring(workout), 0));
}
