import { describe, expect, test } from "vitest";
import {
  GARMIN_CONNECT_BUNDLE_ID,
  activeKcal,
  countedWorkouts,
  everydaySteps,
  workoutCalories,
  withoutDuplicates,
  withoutMultisportParents,
} from "./workouts";

const at = (time: string) => Date.parse(`2026-10-11T${time}:00Z`);
const garmin = (name: string, start: string, minutes: number) => ({
  name,
  sourceBundleId: GARMIN_CONNECT_BUNDLE_ID,
  startAt: at(start),
  durationSec: minutes * 60,
});

describe("withoutMultisportParents", () => {
  test("hides the parent of a real triathlon and keeps every leg", () => {
    const race = [
      garmin("parent", "08:11", 338),
      garmin("swim", "08:11", 30),
      garmin("t1", "08:42", 9),
      garmin("bike", "08:51", 190),
      garmin("t2", "12:02", 7),
      garmin("run", "12:09", 99),
    ];
    expect(withoutMultisportParents(race).map((w) => w.name)).toEqual([
      "swim",
      "t1",
      "bike",
      "t2",
      "run",
    ]);
  });

  test("keeps separate workouts on the same day", () => {
    const day = [garmin("ride", "15:29", 70), garmin("swim", "19:18", 47)];
    expect(withoutMultisportParents(day)).toEqual(day);
  });

  test("keeps a workout that spans only one other", () => {
    const day = [garmin("ride", "09:00", 120), garmin("stop", "09:30", 10)];
    expect(withoutMultisportParents(day)).toEqual(day);
  });

  test("ignores workouts from other apps", () => {
    const day = [
      garmin("ride", "09:00", 120),
      { ...garmin("mobility", "09:10", 6), sourceBundleId: "eu.gowod" },
      { ...garmin("mobility", "09:20", 6), sourceBundleId: "eu.gowod" },
    ];
    expect(withoutMultisportParents(day)).toEqual(day);
  });
});

describe("activeKcal", () => {
  const bmr = 1800;

  test("uses Garmin's figure when it recorded basal energy", () => {
    const swim = { sourceBundleId: GARMIN_CONNECT_BUNDLE_ID, durationSec: 2820, kcal: 584, basalKcal: 80 };
    expect(activeKcal(swim, bmr)).toBe(584);
  });

  test("takes resting energy off an upload with no basal figure", () => {
    const rouvy = { sourceBundleId: GARMIN_CONNECT_BUNDLE_ID, durationSec: 4200, kcal: 774 };
    expect(activeKcal(rouvy, bmr)).toBeCloseTo(686.5);
  });

  test("leaves it alone without a BMR", () => {
    const rouvy = { sourceBundleId: GARMIN_CONNECT_BUNDLE_ID, durationSec: 4200, kcal: 774 };
    expect(activeKcal(rouvy, undefined)).toBe(774);
  });

  test("leaves other apps alone", () => {
    expect(activeKcal({ sourceBundleId: "eu.gowod", durationSec: 360, kcal: 18 }, bmr)).toBe(18);
  });

  test("never goes below zero, and treats missing calories as zero", () => {
    const low = { sourceBundleId: GARMIN_CONNECT_BUNDLE_ID, durationSec: 3600, kcal: 10 };
    expect(activeKcal(low, bmr)).toBe(0);
    expect(activeKcal({ sourceBundleId: "eu.gowod", durationSec: 60 }, bmr)).toBe(0);
  });
});

describe("withoutDuplicates", () => {
  const ride = (name: string, start: string, minutes: number, kcal: number) => ({
    ...garmin(name, start, minutes),
    sport: "ride",
    kcal,
  });

  test("keeps the higher of two devices recording the same ride", () => {
    const pair = [ride("edge", "07:49", 159, 1488), ride("watch", "07:49", 158, 1898)];
    expect(withoutDuplicates(pair).map((w) => w.name)).toEqual(["watch"]);
  });

  test("catches the same session across apps", () => {
    const pair = [ride("garmin", "09:00", 60, 600), { ...ride("watch", "09:01", 60, 500), sourceBundleId: "com.apple.health" }];
    expect(withoutDuplicates(pair).map((w) => w.name)).toEqual(["garmin"]);
  });

  test("keeps different sports and sessions that barely overlap", () => {
    const day = [ride("a", "09:00", 60, 600), ride("b", "09:50", 60, 600), { ...ride("run", "09:00", 60, 600), sport: "run" }];
    expect(withoutDuplicates(day)).toEqual(day);
  });

  test("a transition is not a duplicate of its parent", () => {
    const day = [ride("parent", "08:00", 300, 5000), ride("transition", "09:00", 8, 60)];
    expect(withoutDuplicates(day)).toEqual(day);
  });
});

describe("countedWorkouts", () => {
  test("handles a real race with two bike recordings and a very short transition", () => {
    const leg = (name: string, sport: string, start: string, minutes: number, kcal: number) => ({
      ...garmin(name, start, minutes),
      sport,
      kcal,
    });
    const race = [
      leg("parent", "other", "07:25", 88, 1400),
      leg("swim", "swim", "07:25", 16.5, 195),
      leg("t1", "other", "07:41", 5, 77),
      leg("bike", "ride", "07:46", 42.3, 566),
      leg("bike copy", "ride", "07:46", 38.6, 564),
      leg("t2", "other", "08:28", 0.7, 1),
      leg("run", "run", "08:29", 23.7, 412),
    ];
    expect(countedWorkouts(race).map((w) => w.name)).toEqual(["swim", "t1", "bike", "t2", "run"]);
  });
});

describe("everydaySteps", () => {
  test("removes running and walking, but not other sports", () => {
    const run = { sport: "run", durationSec: 3000 };
    const hike = { sport: "hike", durationSec: 3600, distanceM: 1000 };
    const ride = { sport: "ride", durationSec: 3600, distanceM: 30000 };
    expect(everydaySteps(15000, [run, hike, ride])).toBe(15000 - 8250 - 1300);
  });

  test("never goes below zero", () => {
    expect(everydaySteps(1000, [{ sport: "run", durationSec: 3600 }])).toBe(0);
  });
});

describe("workoutCalories", () => {
  test("adds whole calories per workout, like the rows the app shows", () => {
    const row = { sourceBundleId: "com.example", durationSec: 3600 };
    expect(workoutCalories([{ ...row, kcal: 100.4 }, { ...row, kcal: 100.4 }], 1800)).toBe(200);
  });

  test("takes resting energy off uncorrected Garmin uploads", () => {
    const upload = { sourceBundleId: GARMIN_CONNECT_BUNDLE_ID, durationSec: 3600, kcal: 774 };
    expect(workoutCalories([upload], 1440)).toBe(714);
  });
});
