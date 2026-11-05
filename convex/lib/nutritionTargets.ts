/**
 * Daily calorie and macro targets.
 *
 * - Calories: Mifflin-St Jeor BMR plus everyday activity, adjusted for a weight goal.
 *   Everyday activity comes from a watch's steps when there are any, otherwise from the
 *   activity factor. Neither includes workouts, whose calories are added on top.
 * - Protein: fixed g/kg of body weight.
 * - Fat: fixed share of calories before workouts.
 * - Carbs: the remaining calories, plus workout calories up to 12 g/kg. Fat takes the rest.
 *
 * Pure and dependency-free so it can be unit tested and reused by any Convex function.
 */

export type Sex = "male" | "female";
export type ActivityLevel = "sedentary" | "light" | "moderate";
export type Goal = "lose" | "maintain" | "gain";

export interface NutritionProfile {
  sex: Sex;
  /** "YYYY-MM-DD" */
  birthDate: string;
  heightCm: number;
  weightKg: number;
  activityLevel: ActivityLevel;
  goal: Goal;
  goalRateKgPerWeek: number;
  proteinGPerKg: number;
  fatPercent: number;
}

export interface NutritionTargets {
  /** The day these targets are for, "YYYY-MM-DD". */
  day: string;
  age: number;
  bmr: number;
  /** Calories to maintain weight, excluding workouts. */
  maintenanceCalories: number;
  /** The everyday steps behind `maintenanceCalories`. Absent when the activity factor was used. */
  stepsUsed?: number;
  /** Calories added or removed for the goal (negative when losing). */
  goalAdjustment: number;
  /** Active calories from the day's workouts, included in `calories`. */
  workoutCalories: number;
  calories: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  carbsGPerKg: number;
  /** The requested loss rate exceeded 1% of body weight per week and was reduced. */
  goalRateCapped: boolean;
  /** The goal would have put calories below BMR; calories were raised to BMR. */
  calorieFloorApplied: boolean;
  /** Carbs are below the 3 g/kg lower bound of sports nutrition guidelines. */
  lowCarbs: boolean;
}

/**
 * Non-exercise activity multipliers: everyday movement at work and home, excluding
 * training. (The standard 1.2-1.9 factors include exercise, which would double count
 * once workouts are added.)
 */
export const ACTIVITY_FACTORS: Record<ActivityLevel, number> = {
  sedentary: 1.2, // mostly sitting, e.g. desk job
  light: 1.35, // on your feet part of the day, e.g. teacher, retail
  moderate: 1.5, // on your feet or doing physical work most of the day
};

/** Steps a sedentary day already includes, so the sedentary factor is the base for steps. */
export const BASELINE_STEPS = 2500;
/**
 * Net walking cost: about 2.5 kcal/kg/h above rest at 4.8 km/h (3.5 METs), at 1,300 steps/km.
 * An estimate, like the activity factors. 10,000 extra steps at 70 kg is 280 kcal.
 */
export const KCAL_PER_STEP_PER_KG = 0.0004;

/** Allowed weekly rates per goal, in kg/week. */
export const GOAL_RATES: Record<Goal, readonly number[]> = {
  lose: [0.25, 0.5],
  maintain: [0],
  gain: [0.25],
};

/** Approximate energy in 1 kg of body weight change. */
export const KCAL_PER_KG = 7700;
/** Never plan to lose more than this fraction of body weight per week. */
export const MAX_WEEKLY_LOSS_FRACTION = 0.01;
/** Lower bound of daily carbs for athletes (light training), in g/kg. */
export const LOW_CARBS_G_PER_KG = 3;
/** Top of sports nutrition guidelines (ACSM 2016): workouts only raise carbs this far. */
export const MAX_CARBS_G_PER_KG = 12;

export const PROTEIN_G_PER_KG_RANGE = { min: 1.2, max: 2.0 } as const;
export const FAT_PERCENT_RANGE = { min: 20, max: 35 } as const;

const KCAL_PER_G = { protein: 4, carbs: 4, fat: 9 } as const;

const DAY_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

/** Parses "YYYY-MM-DD", returning null for malformed or impossible dates. */
export function parseDay(
  day: string,
): { year: number; month: number; day: number } | null {
  const match = DAY_PATTERN.exec(day);
  if (!match) return null;
  const [year, month, dayOfMonth] = match.slice(1).map(Number);
  const date = new Date(Date.UTC(year, month - 1, dayOfMonth));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== dayOfMonth
  ) {
    return null;
  }
  return { year, month, day: dayOfMonth };
}

/** Age in whole years on `day`. Both dates are "YYYY-MM-DD". */
export function ageOn(birthDate: string, day: string): number {
  const birth = parseDay(birthDate);
  const on = parseDay(day);
  if (!birth || !on) throw new Error(`Invalid date: ${birthDate} / ${day}`);
  const hadBirthday =
    on.month > birth.month ||
    (on.month === birth.month && on.day >= birth.day);
  return on.year - birth.year - (hadBirthday ? 0 : 1);
}

/** Mifflin-St Jeor basal metabolic rate, kcal/day. */
export function mifflinStJeor(input: {
  sex: Sex;
  weightKg: number;
  heightCm: number;
  age: number;
}): number {
  const base = 10 * input.weightKg + 6.25 * input.heightCm - 5 * input.age;
  return input.sex === "male" ? base + 5 : base - 161;
}

/** A day's steps, without workouts. */
export interface StepsInput {
  everydaySteps: number;
  /** The day isn't over, so the count is still low. */
  inProgress: boolean;
}

function maintenanceFor(
  profile: NutritionProfile,
  bmr: number,
  steps: StepsInput | undefined,
): { maintenance: number; stepsUsed?: number } {
  const fromFactor = bmr * ACTIVITY_FACTORS[profile.activityLevel];
  if (!steps) return { maintenance: fromFactor };

  const extraSteps = Math.max(0, steps.everydaySteps - BASELINE_STEPS);
  const fromSteps =
    bmr * ACTIVITY_FACTORS.sedentary + extraSteps * KCAL_PER_STEP_PER_KG * profile.weightKg;
  // A morning's steps would make today's target start low and climb all day.
  if (steps.inProgress && fromSteps < fromFactor) return { maintenance: fromFactor };
  return { maintenance: fromSteps, stepsUsed: Math.round(steps.everydaySteps) };
}

export function computeTargets(
  profile: NutritionProfile,
  day: string,
  steps?: StepsInput,
  workoutCalories = 0,
): NutritionTargets {
  const age = ageOn(profile.birthDate, day);
  const bmr = mifflinStJeor({ ...profile, age });
  const { maintenance, stepsUsed } = maintenanceFor(profile, bmr, steps);

  const requestedRate = profile.goal === "maintain" ? 0 : profile.goalRateKgPerWeek;
  const rate =
    profile.goal === "lose"
      ? Math.min(requestedRate, profile.weightKg * MAX_WEEKLY_LOSS_FRACTION)
      : requestedRate;
  const direction = profile.goal === "lose" ? -1 : profile.goal === "gain" ? 1 : 0;
  const goalCalories = maintenance + (direction * rate * KCAL_PER_KG) / 7;

  const baseCalories = Math.round(Math.max(goalCalories, bmr));
  const proteinG = Math.round(profile.weightKg * profile.proteinGPerKg);
  const baseFatG = Math.round((baseCalories * profile.fatPercent) / 100 / KCAL_PER_G.fat);
  const baseCarbsG = Math.max(
    0,
    Math.round(
      (baseCalories - proteinG * KCAL_PER_G.protein - baseFatG * KCAL_PER_G.fat) /
        KCAL_PER_G.carbs,
    ),
  );

  const carbsRoomG = Math.max(0, profile.weightKg * MAX_CARBS_G_PER_KG - baseCarbsG);
  const workoutCarbsKcal = Math.min(workoutCalories, carbsRoomG * KCAL_PER_G.carbs);
  const carbsG = baseCarbsG + Math.round(workoutCarbsKcal / KCAL_PER_G.carbs);
  const fatG = baseFatG + Math.round((workoutCalories - workoutCarbsKcal) / KCAL_PER_G.fat);
  const carbsGPerKg = Math.round((carbsG / profile.weightKg) * 10) / 10;

  return {
    day,
    age,
    bmr: Math.round(bmr),
    maintenanceCalories: Math.round(maintenance),
    stepsUsed,
    goalAdjustment: baseCalories - Math.round(maintenance),
    workoutCalories,
    calories: baseCalories + workoutCalories,
    proteinG,
    carbsG,
    fatG,
    carbsGPerKg,
    goalRateCapped: rate < requestedRate,
    calorieFloorApplied: goalCalories < bmr,
    lowCarbs: carbsG / profile.weightKg < LOW_CARBS_G_PER_KG,
  };
}
