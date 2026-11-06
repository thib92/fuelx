// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

type Unit = { stringUnit: { state: string; value: string } };
type Entry = { localizations?: { fr?: Unit } };

function catalog(name: string): [string, Entry][] {
  const file = JSON.parse(readFileSync(`fuelx/${name}.xcstrings`, "utf8"));
  return Object.entries(file.strings);
}

/** The arguments a string takes, whatever order a translation puts them in. */
function specifiers(text: string): string[] {
  const found = text.match(/%(?:\d+\$)?(?:@|lld)/g) ?? [];
  return found.map((specifier) => specifier.replace(/\d+\$/, "")).sort();
}

describe.each(["Localizable", "InfoPlist"])("%s catalog", (name) => {
  test("every string has a French translation", () => {
    const missing = catalog(name)
      .filter(([, entry]) => entry.localizations?.fr?.stringUnit.state !== "translated")
      .map(([key]) => key);
    expect(missing).toEqual([]);
  });
});

test("translations take the same arguments as their English", () => {
  for (const [key, entry] of catalog("Localizable")) {
    expect(specifiers(entry.localizations!.fr!.stringUnit.value), key).toEqual(specifiers(key));
  }
});

test("the app words every user error", () => {
  const backend = readFileSync("convex/lib/userError.ts", "utf8");
  const app = readFileSync("fuelx/Nutrition/NutritionModels.swift", "utf8");
  const codes = [...backend.matchAll(/\| "(\w+)"/g)].map((match) => match[1]);
  expect(codes.length).toBeGreaterThan(0);
  for (const code of codes) expect(app, code).toContain(`case "${code}":`);
});
