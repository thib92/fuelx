# Meal Logging Phase 1 (Core and Search) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mock meals in the day view with real logging: search CIQUAL and Open Food Facts, add foods by grams, repeat recents, copy yesterday, create custom foods.

**Architecture:** Nutrition rules, search normalisation and ranking are pure TypeScript in `convex/lib/`. Convex functions own all calculations, so `logs:forDay` returns computed kcal and macros and Swift only displays them. Import scripts turn the CIQUAL and OFF dumps into `foods` documents using the same quality module that phase 2 will use for live lookups.

**Tech Stack:** Convex 1.49, TypeScript, vitest + convex-test, DuckDB CLI (extraction only), tsx (scripts), SwiftUI, ConvexMobile.

**Spec:** `docs/superpowers/specs/2026-11-05-meal-logging-design.md`

## Global Constraints

- Days are local date strings, `YYYY-MM-DD`, validated with `parseDay` from `convex/lib/nutritionTargets.ts`.
- Macro and calorie numbers are per 100 g in `foods`; each `logEntries` row keeps its own `per100g` snapshot, so refreshes never change history.
- Every public function follows `convex/profile.ts`: `args` and `returns` validators, identity from `ctx.auth.getUserIdentity()`, `ConvexError` with a readable message.
- Search: fetch 50, normalise both stored text and queries, at most 16 query terms.
- Popularity boost threshold is `offScans >= 20`; blank counts are never penalised.
- Rule 7 and rule 1 apply to the bulk import only. Rules 2–6 live in `convex/lib/foodQuality.ts`.
- A refresh never touches `label` or `custom` foods.
- New Swift files need no project edits: `fuelx/` is a synchronized Xcode group. Numbers from Convex decode as `Double`.
- There is no Swift test target. Logic belongs in Convex where it is tested; Swift tasks are checked by a build and a manual pass.
- `aiUsage`, barcode scanning and the Scan/Photo/Describe buttons belong to phases 2 and 3.

## Review Focus

1. A guest with log entries but no profile signs in with Apple: entries must still move, though `profile:transferOnLink` currently returns early when there is no guest profile (Task 5).
2. Grams of 0, negative, NaN or above 5,000 are rejected on the server, whatever the app sends (Task 4).
3. A search that normalises to nothing, such as `"!!!"`, or one with over 16 words, returns a normal result instead of throwing (Tasks 2 and 3).
4. A user cannot read, change or delete another user's entries, and cannot log another user's custom food (Tasks 3 and 4).
5. Copying a meal onto itself is rejected, and copying twice is prevented in the UI, since the server allows adding to a non-empty meal (Tasks 4 and 9).

---

### Task 1: Food quality rules

**Files:**
- Create: `convex/lib/foodQuality.ts`
- Test: `convex/lib/foodQuality.test.ts`

**Interfaces:**
- Produces:
  - `type Per100g = { kcal: number; proteinG: number; carbsG: number; fatG: number; sugarG?: number; fiberG?: number; saltG?: number }`
  - `type FoodCandidate = { barcode: string; name: string; per100g: Per100g; alcoholPct?: number }`
  - `expectedKcal(per100g: Per100g, alcoholPct?: number): number`
  - `isPlausible(per100g: Per100g, alcoholPct?: number): boolean` (rules 5 and 6)
  - `checkFood(food: FoodCandidate): { ok: true } | { ok: false; rule: "barcode" | "name" | "range" | "calories" }` (rules 2, 3, 5, 6, checked in that order)
  - `kcalFromKj(kj: number): number`

- [ ] **Step 1: Write the failing tests**

```ts
const clean = { barcode: "3017620422003", name: "Pâte à tartiner", per100g: { kcal: 539, proteinG: 6.3, carbsG: 57.5, fatG: 30.9 } };

test("accepts a normal product", () => expect(checkFood(clean)).toEqual({ ok: true }));
test.each(["12345", "abcdefghijklm", "123456789"])("rejects barcode %s", (barcode) =>
  expect(checkFood({ ...clean, barcode })).toEqual({ ok: false, rule: "barcode" }));
test.each(["12345678", "123456789012", "1234567890123", "12345678901234"])("accepts barcode %s", (barcode) =>
  expect(checkFood({ ...clean, barcode }).ok).toBe(true));
test("rejects names under 3 alphanumerics after cleaning", () =>
  expect(checkFood({ ...clean, name: "a!" })).toEqual({ ok: false, rule: "name" }));
test("rejects non-Latin-only names", () =>
  expect(checkFood({ ...clean, name: "زيت" })).toEqual({ ok: false, rule: "name" }));
test("rejects kcal over 950 and macros over 105 g in total", () => {
  expect(checkFood({ ...clean, per100g: { ...clean.per100g, kcal: 951 } })).toEqual({ ok: false, rule: "range" });
  expect(checkFood({ ...clean, per100g: { kcal: 400, proteinG: 40, carbsG: 40, fatG: 26 } })).toEqual({ ok: false, rule: "range" });
});
test("rejects butter listed at half its energy", () =>
  expect(checkFood({ ...clean, per100g: { kcal: 375, proteinG: 0.7, carbsG: 0.6, fatG: 82 } })).toEqual({ ok: false, rule: "calories" }));
test("accepts water", () =>
  expect(checkFood({ ...clean, per100g: { kcal: 0, proteinG: 0, carbsG: 0, fatG: 0 } }).ok).toBe(true));
test("counts alcohol energy: pastis passes", () =>
  expect(checkFood({ ...clean, per100g: { kcal: 274, proteinG: 0, carbsG: 0, fatG: 0 }, alcoholPct: 45 }).ok).toBe(true));
test("counts fibre energy", () =>
  expect(checkFood({ ...clean, per100g: { kcal: 240, proteinG: 10, carbsG: 20, fatG: 5, fiberG: 40 } }).ok).toBe(true));
test("expectedKcal applies the spec formula", () =>
  expect(expectedKcal({ kcal: 0, proteinG: 10, carbsG: 20, fatG: 5, fiberG: 3 }, 10)).toBeCloseTo(40 + 80 + 45 + 6 + 55.23, 2));
```

- [ ] **Step 2: Run `npx vitest run convex/lib/foodQuality.test.ts`.** Expected: FAIL, module not found.

- [ ] **Step 3: Implement in `convex/lib/foodQuality.ts`.** Formula and limits come from the spec's rules 5 and 6: alcohol grams = alcohol % × 0.789; pass if gap ≤ max(40, 30% of the larger of listed and expected). Name check normalises with the same steps as Task 2's step 1 (lowercase, strip accents, non-alphanumerics to spaces), so export `cleanText(s: string): string` from this file and reuse it in Task 2.

- [ ] **Step 4: Run the tests.** Expected: PASS.

- [ ] **Step 5: Commit** with message `Add food quality rules`.

### Task 2: Search normalisation and ranking

**Files:**
- Create: `convex/lib/foodSearch.ts`
- Test: `convex/lib/foodSearch.test.ts`

**Interfaces:**
- Consumes: `cleanText` from Task 1.
- Produces:
  - `normalizeTerms(text: string): string[]` (at most 16)
  - `searchTextFor(food: { name: string; nameEn?: string; brand?: string }): string`
  - `rankFoods<T extends { _id: string; searchText: string; offScans?: number }>(foods: T[], queryTerms: string[], recentIds: Set<string>): T[]`
  - `POPULAR_SCANS = 20`

- [ ] **Step 1: Write the failing tests**

```ts
test("normalises accents, case and plurals", () => {
  expect(normalizeTerms("Pâtes")).toEqual(["pate"]);
  expect(normalizeTerms("YAOURTS nature")).toEqual(["yaourt", "nature"]);
  expect(normalizeTerms("choux")).toEqual(["chou"]);
  expect(normalizeTerms("riz")).toEqual(["riz"]);
});
test("returns nothing for punctuation", () => expect(normalizeTerms("!!! ...")).toEqual([]));
test("keeps 16 terms at most", () =>
  expect(normalizeTerms(Array.from({ length: 30 }, (_, i) => `mot${i}`).join(" "))).toHaveLength(16));
test("search text joins name, English name and brand", () =>
  expect(searchTextFor({ name: "Filets de poulet", nameEn: "Chicken breast", brand: "Herta" }))
    .toBe("filet de poulet chicken breast herta"));
test("the 16-term cap applies to queries, not stored text", () =>
  expect(searchTextFor({ name: Array.from({ length: 30 }, (_, i) => `mot${i}`).join(" ") }).split(" ")).toHaveLength(30));

const f = (id: string, searchText: string, offScans?: number) => ({ _id: id, searchText, offScans });
test("ranks recents, then all-terms matches, then the rest", () => {
  const out = rankFoods(
    [f("tea", "nat form tisane"), f("yog", "yaourt nature cora"), f("rec", "yaourt fraise")],
    ["yaourt", "nat"], new Set(["rec"]));
  expect(out.map((x) => x._id)).toEqual(["rec", "yog", "tea"]);
});
test("popular products rise within their group; blank counts keep their order", () => {
  const out = rankFoods(
    [f("a", "skyr", undefined), f("b", "skyr", 5), f("c", "skyr", 20), f("d", "skyr", 1000)],
    ["skyr"], new Set());
  expect(out.map((x) => x._id)).toEqual(["d", "c", "a", "b"]);
});
```

- [ ] **Step 2: Run `npx vitest run convex/lib/foodSearch.test.ts`.** Expected: FAIL, module not found.

- [ ] **Step 3: Implement in `convex/lib/foodSearch.ts`.** Strip a trailing `s` or `x` only from tokens of 4 or more characters. "Contains every term" treats the last query term as a prefix, matching Convex. Popular items in a group sort by `offScans` descending; everything else keeps input order (use a stable sort).

- [ ] **Step 4: Run the tests.** Expected: PASS.

- [ ] **Step 5: Commit** with message `Add food search normalisation and ranking`.

### Task 3: Foods table, search and custom foods

**Files:**
- Modify: `convex/schema.ts`
- Create: `convex/foods.ts`
- Test: `convex/foods.test.ts`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
  - Schema: `foods` with fields as in the spec, indexes `by_barcode`, `by_source_sourceId`, and search index `search_text` on `searchText` with filter fields `source`, `ownerId`. Also export `per100gValidator`, `foodSourceValidator`, and `importDocValidator` from `schema.ts`.
  - `type ImportDoc = Infer<typeof importDocValidator>`, exported from `schema.ts`: `source` (`ciqual` or `off`), `sourceId`, `barcode?`, `name`, `nameEn?`, `brand?`, `searchText`, `per100g`, `servingG?`, `offScans?`.
  - `foods:search({ query: string }) => FoodResult[]`, at most 25.
  - `foods:createCustom({ name: string, brand?: string, per100g, servingG?: number }) => Id<"foods">`
  - `foods:importBatch({ secret: string, docs: ImportDoc[] }) => { inserted: number, updated: number, unchanged: number }`
  - `FoodResult = { _id, name, brand?, source, per100g, servingG? }`

- [ ] **Step 1: Write the failing tests** in `convex/foods.test.ts`, following `convex/profile.test.ts` setup. Seed with `t.run`, using `searchTextFor` for `searchText`.

```ts
test("signed-out search returns nothing", ...);
test("finds foods with accents in the query", async () => {
  // seed name "Pâtes complètes"; expect search({ query: "pâtes" }) to return it
});
test("blank or punctuation queries return an empty list", async () => {
  // expect search({ query: "!!!" }) and search({ query: "" }) to equal []
});
test("a query of 30 words does not throw", ...);
test("custom foods are visible to their owner only", async () => {
  // alice creates custom "Bowl maison"; alice finds it, bob gets []
});
test("recent foods rank first", async () => {
  // two foods match; insert recentFoods row for the second; expect it first
});
test("createCustom rejects implausible macros", async () => {
  // per100g fat 200 rejects with "values"; name "" rejects with "name"
});
test("importBatch rejects a wrong secret", ...);  // FOODS_IMPORT_SECRET via vi.stubEnv
test("importBatch inserts, updates changed docs and skips unchanged ones", async () => {
  // first call: { inserted: 2, updated: 0, unchanged: 0 }
  // same docs: { inserted: 0, updated: 0, unchanged: 2 }
  // changed kcal on one: { inserted: 0, updated: 1, unchanged: 1 }
});
test("importBatch never touches label or custom foods", async () => {
  // seed a label food with the same sourceId; importing source "off" leaves it unchanged
});
```

`recentFoods` is needed by the ranking test, so add it to the schema in this task, as specified in the spec, with indexes `by_user_lastUsed` on `["userId", "lastUsedAt"]` and `by_user_food` on `["userId", "foodId"]`.

- [ ] **Step 2: Run `npx vitest run convex/foods.test.ts`.** Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `search` runs two searches of 50 each, public foods (`ownerId` undefined) and the caller's own (`ownerId` = caller), merges them, reads up to 200 of the caller's `recentFoods`, and returns the top 25 of `rankFoods`.
  - `createCustom` uses `source: "custom"`, a generated `sourceId` (`crypto.randomUUID()`), and `isPlausible`; `ConvexError("Those values don't add up.")` otherwise, and `ConvexError("Enter a name.")` for a name under 2 characters after trimming. Cap names at 120 characters. Rejecting on `isPlausible` is stricter than the spec wording, but is required so users' typos cannot break their totals.
  - `importBatch` is a public mutation guarded by comparing `secret` with `process.env.FOODS_IMPORT_SECRET`; if the env var is unset, always reject. Accept at most 500 docs and only `source` `ciqual` or `off`. Compare field by field before writing.

- [ ] **Step 4: Run `npm test`.** Expected: all PASS. If convex-test's search approximation differs from production, keep the test and verify in Task 6.

- [ ] **Step 5: Commit** with message `Add foods table, search and custom foods`.

### Task 4: Log entries

**Files:**
- Modify: `convex/schema.ts`
- Create: `convex/lib/logMath.ts`, `convex/logs.ts`
- Test: `convex/lib/logMath.test.ts`, `convex/logs.test.ts`

**Interfaces:**
- Consumes: `recentFoods` and `per100gValidator` from Task 3.
- Produces:
  - Schema: `logEntries` as in the spec, with index `by_user_day` on `["userId", "day"]`, and `mealValidator` exported.
  - `entryNutrition(grams: number, per100g: Per100g): { kcal, proteinG, carbsG, fatG }` (unrounded) and `sumNutrition(items): {...}` in `logMath.ts`.
  - `logs:forDay({ day }) => { entries: EntryView[], totals: Totals, mealTotals: Record<meal, Totals> } | null`, with entries oldest first and null when signed out. Totals are summed unrounded, then kcal rounds to an integer and macros to 1 decimal.
  - `EntryView = { _id, meal, name, brand?, grams, kcal, proteinG, carbsG, fatG, estimated, foodId? }`
  - `logs:add({ day, meal, foodId, grams, origin }) => Id<"logEntries">`
  - `logs:update({ id, grams?, meal? }) => null`
  - `logs:remove({ id }) => null`
  - `logs:copyMeal({ fromDay, toDay, meal }) => number` (entries copied)
  - `logs:recents({ limit? }) => { foodId, name, brand?, source, per100g, servingG?, lastGrams }[]`, default 30, most recent first.

- [ ] **Step 1: Write the failing tests.**

```ts
// logMath.test.ts
test("scales per 100 g values by grams", () =>
  expect(entryNutrition(150, { kcal: 110, proteinG: 23, carbsG: 0, fatG: 2 }))
    .toEqual({ kcal: 165, proteinG: 34.5, carbsG: 0, fatG: 3 }));

// logs.test.ts
test("add snapshots the food, so editing the food later changes nothing");
test("add creates a recent; a second add bumps useCount and lastGrams");
test.each([0, -5, NaN, Infinity, 5001])("add rejects grams %s", ...);  // toThrow("Grams")
test("add and forDay reject a malformed day");
test("forDay totals sum unrounded values and return mealTotals");
test("entries are private: bob's forDay is empty; bob's update and remove throw");
test("a food owned by another user cannot be logged");
test("update changes grams but keeps the snapshot");
test("copyMeal copies snapshots, with origin copy, and returns the count");
test("copyMeal returns 0 for an empty source meal");
test("copyMeal rejects fromDay === toDay");
test("copyMeal still copies an entry whose foodId is absent");
test("recents returns the food's current data and lastGrams, newest first");
```

- [ ] **Step 2: Run `npx vitest run convex/lib/logMath.test.ts convex/logs.test.ts`.** Expected: FAIL.

- [ ] **Step 3: Implement.** Grams must be finite, above 0, and at most 5,000; else `ConvexError("Grams must be between 0 and 5000.")`. `add` loads the food, rejects with `ConvexError("Food not found.")` if missing or owned by someone else, and sets `estimated: false`. Share the recents update in a local helper `touchRecent(ctx, userId, foodId, grams)`, also called by `copyMeal` for entries with a `foodId`. The `logs:add` `origin` argument accepts only `search` and `recent`; the `logEntries` field keeps the spec's full union for later phases.

- [ ] **Step 4: Run `npm test`.** Expected: all PASS.

- [ ] **Step 5: Commit** with message `Add log entries and recents`.

### Task 5: Guest data transfer

**Files:**
- Modify: `convex/profile.ts:74-87`, `convex/logs.ts`
- Test: `convex/profile.test.ts`

**Interfaces:**
- Consumes: tables from Tasks 3 and 4.
- Produces: `transferLogData(ctx: MutationCtx, fromUserId: string, toUserId: string): Promise<void>` exported from `convex/logs.ts`, moving `logEntries`, `recentFoods`, and `custom` foods.

- [ ] **Step 1: Write the failing tests** in `convex/profile.test.ts`:

```ts
test("transferOnLink moves entries even when the guest has no profile");
test("transferOnLink merges recents: latest date, summed counts, latest grams");
test("transferOnLink moves custom foods, and they stay searchable by the new owner");
test("transferOnLink keeps the existing account's entries and adds the guest's");
```

- [ ] **Step 2: Run `npx vitest run convex/profile.test.ts`.** Expected: the new tests FAIL.

- [ ] **Step 3: Implement.** Call `transferLogData` before the `guestProfile` early return in `transferOnLink`. Custom foods need `ownerId` patched. Update the doc comment.

- [ ] **Step 4: Run `npm test`.** Expected: all PASS.

- [ ] **Step 5: Commit** with message `Transfer logs and recents when a guest links an account`.

### Task 6: Import scripts and the real import

**Files:**
- Create: `scripts/foods/extract-off.sql`, `scripts/foods/mapping.ts`, `scripts/foods/build.ts`, `scripts/foods/upload.ts`, `scripts/foods/README.md`
- Modify: `package.json`, `.gitignore`
- Test: `scripts/foods/mapping.test.ts`

**Interfaces:**
- Consumes: `checkFood`, `expectedKcal`, `kcalFromKj` (Task 1), `searchTextFor` (Task 2), `foods:importBatch` (Task 3).
- Produces:
  - `parseCiqualValue(raw: string): number | undefined`
  - `ciqualFood(code, nameFr, nameEn, values): ImportDoc | null` (no `checkFood`: CIQUAL has no barcode and is curated, so it only needs complete macros)
  - `offFood(row: OffRow): ImportDoc | null`

- [ ] **Step 1: Write the failing tests:**

```ts
test.each([["12,3", 12.3], ["traces", 0], ["< 0,5", 0.5], ["-", undefined], ["", undefined]])(
  "parses %s", (raw, want) => expect(parseCiqualValue(raw)).toBe(want));
test("computes missing CIQUAL kcal from macros", ...);
test("drops CIQUAL foods missing a macro", ...);  // returns null
test("offFood prefers the French name and keeps the first brand", ...);
test("offFood uses kJ when kcal is missing", ...);
test("offFood drops a product with neither brand nor scans (rule 7)", ...);
test("offFood keeps a scanned product without a brand", ...);
test("offFood drops a product that fails checkFood", ...);
test("offFood rounds values and omits missing optional fields", ...);
```

Round kcal to 0 decimals, macros to 1, salt to 2. Ignore `servingG` outside 0–5,000.

- [ ] **Step 2: Run `npx vitest run scripts/foods/mapping.test.ts`.** Expected: FAIL.

- [ ] **Step 3: Implement the scripts.**
  - `extract-off.sql` reads `food.parquet`, applies rule 1, and writes JSONL with `code, name_fr, name_main, brands, kcal, kj, proteins, carbohydrates, fat, sugars, fiber, salt, alcohol, serving_quantity, unique_scans_n`. Read each nutrient from `nutriments` by name via its `100g` field.
  - `build.ts` reads that file and the CIQUAL XML (`alim`, `compo`), and writes `foods.jsonl`, printing kept and rejected counts per rule. CIQUAL nutrient codes: 328 kcal, 25000 protein, 31000 carbs, 40000 fat, 32000 sugars, 34100 fibre, 10004 salt.
  - `upload.ts` sends 500 documents per call with `ConvexHttpClient`, using `CONVEX_URL` and `FOODS_IMPORT_SECRET`. It prints running totals and can resume from a line number after a failure.
  - `README.md` records download URLs (spec dataset `doi:10.57745/RDMHWY` and OFF's Parquet export), run order, and the refresh steps.
  - Add `tsx` to devDependencies, and `scripts/foods/data/` to `.gitignore`.

- [ ] **Step 4: Run `npm test`, then run the extract and build.** Expected: tests PASS, and within 1% of 619,653 OFF foods and at least 3,323 CIQUAL foods. Investigate any wider gap before uploading.

- [ ] **Step 5: Upload to dev.** Set `FOODS_IMPORT_SECRET` with `npx convex env set`, run `npx convex dev --once`, then `npx tsx scripts/foods/upload.ts`. Expected: inserted count equals the `foods.jsonl` line count, in about 10 minutes.

- [ ] **Step 6: Check limits, and clean up.** Ask the owner to read storage and bandwidth from the Convex dashboard. The target is under 450 MB of database storage. If over, stop and raise rule 7's threshold with the owner. Verify with `npx convex run foods:search` as a signed-in identity that "pâtes" and "skyr" return real products. Empty and remove `foods_sample`.

- [ ] **Step 7: Commit** with message `Add food import scripts`.

### Task 7: Day view on real data

**Files:**
- Create: `fuelx/Logging/LogModels.swift`
- Modify: `fuelx/Home/DayLog.swift`, `fuelx/Home/MockDayLogs.swift`, `fuelx/Home/DayPage.swift`, `fuelx/Home/HomeView.swift:28`, `fuelx/Nutrition/TargetsCard.swift`

**Interfaces:**
- Consumes: `logs:forDay` (Task 4).
- Produces:
  - `MealKind` (`String`, `Codable`, cases `breakfast`, `lunch`, `dinner`, `snack`), with `label` and `systemImage`, replacing `Meal.Kind`.
  - `LogEntry`, `NutritionTotals`, `DayEntries`, `Decodable & Sendable`, mirroring `EntryView`, `Totals` and `forDay`.
  - `DayPage(day: Date, workouts: [Workout], onSetUpProfile: () -> Void)`.
  - `MockDayLogs.workouts(for:now:) -> [Workout]`.

- [ ] **Step 1: Add `LogModels.swift`.** Models are `nonisolated`, as in `NutritionModels.swift`. Add `@State private var dayEntries: DayEntries??`, matching the existing `targets` pattern.

- [ ] **Step 2: Rework the view.** Remove `Meal`; `DayLog` keeps `workouts` and takes `mealCalories: Int` from `totals.kcal`. Subscribe to `logs:forDay` alongside `nutrition:targetsForDay` in separate `.task(id:)` blocks. Always show all four meal sections, each header showing kcal, with one row per entry (name, brand, grams, kcal). Workouts and mock fuel stay as they are. An "Estimated" label shows on `estimated` entries.

- [ ] **Step 3: Update `TargetsCard`** with `eaten: NutritionTotals?`, showing "32 of 120 g" per macro when present. Macros come from logged entries only.

- [ ] **Step 4: Build.** Run `xcodebuild -scheme fuelx -destination 'generic/platform=iOS Simulator' build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit** with message `Show logged meals in the day view`.

### Task 8: Add food flow

**Files:**
- Create: `fuelx/Logging/AddFoodSheet.swift`, `fuelx/Logging/AmountView.swift`
- Modify: `fuelx/Logging/LogModels.swift`, `fuelx/Home/DayPage.swift`

**Interfaces:**
- Consumes: `foods:search`, `logs:recents`, `logs:add`.
- Produces: `AddFoodSheet(day: Date, meal: MealKind)`, and `FoodResult`, `RecentFood` models. `AmountView(food:, initialGrams:, primaryTitle:, onSubmit: (Double) async throws -> Void)`, reused by Task 9.

- [ ] **Step 1: Build `AddFoodSheet`.** A section header add button opens it. Before typing, it lists `logs:recents`. Typing searches after 250 ms using `.task(id: query)` with `Task.sleep`, which cancels stale searches. Rows show name, brand and kcal per 100 g. States: empty results show "No Results" with a link to Task 9's custom food sheet; failures show `convexMessage`.

- [ ] **Step 2: Build `AmountView`.** Grams text field, chips for 50, 100, 150 and 200, and a "1 serving" chip when `servingG` is known. Default grams: `lastGrams`, then `servingG`, then 100. Show live kcal and macros for the entered grams. Disable the button while saving and when grams are not above 0.

- [ ] **Step 3: Build.** Same command as Task 7. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual check on a simulator.** Search "pâtes", add 100 g to lunch, and confirm the day view and `TargetsCard` update without reloading.

- [ ] **Step 5: Commit** with message `Add food search and amount flow`.

### Task 9: Edit, repeat, copy and custom foods

**Files:**
- Create: `fuelx/Logging/CustomFoodForm.swift`
- Modify: `fuelx/Logging/AddFoodSheet.swift`, `fuelx/Home/DayPage.swift`

**Interfaces:**
- Consumes: `logs:update`, `logs:remove`, `logs:copyMeal`, `foods:createCustom`, `logs:add`, `AmountView`.

- [ ] **Step 1: Edit and delete.** Tap an entry to open `AmountView` with `logs:update`. Swipe to delete with `logs:remove`.

- [ ] **Step 2: Repeat.** Each recents row gets a trailing add button that calls `logs:add` with `lastGrams` and `origin: "recent"`, then shows a checkmark for that row. The row button is disabled while saving.

- [ ] **Step 3: Copy yesterday.** Each meal section gets a menu item, "Copy from Yesterday". It is disabled while the call runs, and also once it has succeeded for that meal and day. A result of 0 shows "Nothing to copy".

- [ ] **Step 4: Custom food.** `CustomFoodForm` collects name, optional brand, kcal, protein, carbs, fat per 100 g, and optional serving grams. After `foods:createCustom`, it opens `AmountView` for the new food.

- [ ] **Step 5: Build, then manual check.** Edit grams, delete, repeat a recent, copy a meal, create a custom food. As a guest, log a food, sign in with Apple, and confirm it is still there.

- [ ] **Step 6: Commit** with message `Add edit, repeat, copy and custom foods`.

### Task 10: Attribution and finish

**Files:**
- Create: `fuelx/Account/AboutView.swift`
- Modify: `fuelx/Account/AccountView.swift`, `docs/BACKLOG.md`

- [ ] **Step 1: Add `AboutView`,** linked from the account screen, with this text and links: "Contains data from Open Food Facts, available under the Open Database License." (links to `https://world.openfoodfacts.org` and `https://opendatacommons.org/licenses/odbl/1-0/`), and "Food composition data from the ANSES-Ciqual table, available under Licence Ouverte." (links to `https://ciqual.anses.fr`).

- [ ] **Step 2: Update `docs/BACKLOG.md`.** Remove done items ("Quick add" meals part, "Macros per meal", the `logs:forDay` data layer note) and add that mock fuel still counts toward the calories eaten until workouts are real.

- [ ] **Step 3: Run `npm test` and the Xcode build.** Expected: all PASS, `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit** with message `Add data attribution`.
