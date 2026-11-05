import { describe, expect, test } from "vitest";
import {
  ageOn,
  computeTargets,
  mifflinStJeor,
  parseDay,
  type NutritionProfile,
} from "./nutritionTargets";

const athlete: NutritionProfile = {
  sex: "male",
  birthDate: "1991-03-15",
  heightCm: 178,
  weightKg: 70,
  activityLevel: "moderate",
  goal: "maintain",
  goalRateKgPerWeek: 0,
  proteinGPerKg: 1.6,
  fatPercent: 25,
};

describe("parseDay", () => {
  test("accepts valid dates and rejects malformed or impossible ones", () => {
    expect(parseDay("2026-10-31")).toEqual({ year: 2026, month: 10, day: 31 });
    expect(parseDay("2024-02-29")).not.toBeNull();
    expect(parseDay("2026-02-29")).toBeNull();
    expect(parseDay("2026-13-01")).toBeNull();
    expect(parseDay("31/10/2026")).toBeNull();
  });
});

describe("ageOn", () => {
  test("counts whole years, turning over on the birthday", () => {
    expect(ageOn("1991-03-15", "2026-03-14")).toBe(34);
    expect(ageOn("1991-03-15", "2026-03-15")).toBe(35);
    expect(ageOn("1991-03-15", "2026-10-31")).toBe(35);
  });
});

describe("mifflinStJeor", () => {
  test("matches the published equation", () => {
    // 10*70 + 6.25*178 - 5*35 = 1637.5
    expect(mifflinStJeor({ sex: "male", weightKg: 70, heightCm: 178, age: 35 })).toBe(1642.5);
    expect(mifflinStJeor({ sex: "female", weightKg: 70, heightCm: 178, age: 35 })).toBe(1476.5);
  });
});

describe("computeTargets", () => {
  test("maintenance: protein by weight, fat by share, carbs fill the rest", () => {
    const t = computeTargets(athlete, "2026-10-31");
    expect(t.age).toBe(35);
    expect(t.bmr).toBe(1643);
    expect(t.maintenanceCalories).toBe(2464); // 1642.5 * 1.5
    expect(t.calories).toBe(2464);
    expect(t.goalAdjustment).toBe(0);
    expect(t.proteinG).toBe(112); // 70 * 1.6
    expect(t.fatG).toBe(68); // 25% of 2464 / 9
    expect(t.carbsG).toBe(351); // (2464 - 448 - 612) / 4
    expect(t.carbsGPerKg).toBe(5);
    expect(t).toMatchObject({ goalRateCapped: false, calorieFloorApplied: false, lowCarbs: false });
  });

  test("weight loss subtracts rate * 7700 / 7 per day", () => {
    const t = computeTargets({ ...athlete, goal: "lose", goalRateKgPerWeek: 0.25 }, "2026-10-31");
    expect(t.calories).toBe(2189); // 2463.75 - 275
    expect(t.goalAdjustment).toBe(-275);
    expect(t.proteinG).toBe(112); // protein unchanged during a cut
  });

  test("weight gain adds calories", () => {
    const t = computeTargets({ ...athlete, goal: "gain", goalRateKgPerWeek: 0.25 }, "2026-10-31");
    expect(t.goalAdjustment).toBe(275);
  });

  test("loss rate is capped at 1% of body weight per week", () => {
    const light = { ...athlete, weightKg: 45, goal: "lose" as const, goalRateKgPerWeek: 0.5 };
    const t = computeTargets(light, "2026-10-31");
    expect(t.goalRateCapped).toBe(true);
    // 0.45 kg/week -> 495 kcal/day
    expect(t.maintenanceCalories - t.calories).toBe(495);
  });

  test("activity factors exclude exercise", () => {
    const bmr = 1642.5;
    const maintenance = (activityLevel: NutritionProfile["activityLevel"]) =>
      computeTargets({ ...athlete, activityLevel }, "2026-10-31").maintenanceCalories;
    expect(maintenance("sedentary")).toBe(Math.round(bmr * 1.2));
    expect(maintenance("light")).toBe(Math.round(bmr * 1.35));
    expect(maintenance("moderate")).toBe(Math.round(bmr * 1.5));
  });

  test("calories never go below BMR", () => {
    const t = computeTargets(
      { ...athlete, activityLevel: "sedentary", goal: "lose", goalRateKgPerWeek: 0.5 },
      "2026-10-31",
    );
    // 1642.5 * 1.2 - 550 = 1421 < BMR
    expect(t.calorieFloorApplied).toBe(true);
    expect(t.calories).toBe(1643);
  });

  test("flags carbs below 3 g/kg", () => {
    const t = computeTargets(
      { ...athlete, activityLevel: "sedentary", proteinGPerKg: 2, fatPercent: 35 },
      "2026-10-31",
    );
    expect(t.carbsGPerKg).toBeLessThan(3);
    expect(t.lowCarbs).toBe(true);
  });
});
