# Meal logging design

Date: 2026-11-05

## Goal

Replace the mock meals in the day view with real logging that is on par with or better than
Yazio: database search, barcode scanning, and AI logging from photos and text.

The app is for the owner and friends first (about 10 users, mainly in France, iPhone only), and
may go public later. It must stay cheap to run: target under $5/month at about 900 AI logs/month.

Success means:

- Logging a common meal takes seconds, through recents, repeat and copy.
- Every logged item shows where its numbers came from and can be edited before saving.
- Calories and macros per item feed the existing `TargetsCard`.

## Scope

This design covers three phases that share one data model. Each phase gets its own
implementation plan.

1. **Logging core and search:** food data import, `foods` search, log entries, day view on real
   data, recents, repeat, copy yesterday.
2. **Barcode:** on-device scanning, live Open Food Facts fallback, label photo fallback.
3. **AI logging:** photo and text pipeline, correction box, usage caps, model evaluation.

Out of scope: workouts and fuel logging (workouts stay on `MockDayLogs`; gels are logged as
ordinary foods for now), carbs per hour, HealthKit, imperial units, recipes, Android, and
embeddings or vector search.

## Food data

Sources:

| Source | Role | Licence | Volume |
|---|---|---|---|
| CIQUAL 2025 | Generic foods | Etalab 2.0 | 3,484 foods, 3,323 with complete data |
| Open Food Facts (OFF) | Branded products, barcodes | ODbL | 619,653 selected products |

Prices, licences and counts were checked on 2026-11-05. OFF counts come from its Parquet export.

### OFF import rules

A product is imported only if it passes all of these:

1. `countries_tags` contains `en:france`.
2. Barcode is digits only, with length 8, 12, 13 or 14.
3. Name is the French name, otherwise the main name, with at least 3 letters or digits after
   normalisation.
4. kcal, protein, carbs and fat per 100 g are all present. If kcal is missing, use kJ / 4.184.
5. kcal is 0–950; each macro is 0–100 g; protein + carbs + fat is at most 105 g.
6. Expected kcal = 4 × protein + 4 × carbs + 9 × fat + 2 × fibre + 7 × alcohol grams, where
   alcohol grams = alcohol % × 0.789 and missing fibre or alcohol counts as 0. The gap between
   expected and listed kcal must be at most max(40, 30% of the larger value).
7. The product has a brand or a scan count.

Measured funnel: 1,294,738 → rules 2–5: 891,097 → rule 6: 863,259 → rule 7: 619,653.

`unique_scans_n` is never a filter on its own. It only covers scans from OFF's own apps and is
blank (not zero) for 46% of clean products, including many big French brands and most new
products. 94% of clean products came in through Yuka, which appears not to contribute scan counts.

### CIQUAL import rules

- Keep foods with kcal, protein, carbs and fat.
- If only kcal is missing, compute it with the rule 6 formula.
- Parse `traces` as 0, `< 0,5` as 0.5, `-` as missing, and comma decimals as numbers.
- Search text includes both the French and English names.

### Single source of truth for rules

Quality rules 2–6 live in one TypeScript module, `convex/lib/foodQuality.ts`, used by both the
importer and live OFF lookups. DuckDB only extracts OFF rows into JSONL for the importer. Rule 1
and rule 7 apply to the bulk import only: a person scanning a barcode has the product in hand,
and the barcode identifies it.

### Import and refresh

- `scripts/foods/` holds the extract and import scripts, run by hand. Nothing downloads at runtime.
- Upserts match on `source` + `sourceId`.
- Refresh is a periodic manual re-import. OFF deltas only cover 14 days and cannot report
  deletions, so they are not used.
- A refresh never touches `label` or `custom` foods.

## Data model

All in `convex/schema.ts`.

```ts
foods: {
  source: "ciqual" | "off" | "label" | "custom",
  sourceId: string,          // CIQUAL code, barcode, or generated id
  barcode?: string,
  name: string,
  nameEn?: string,           // CIQUAL only
  brand?: string,
  searchText: string,        // normalised name + brand; see Search
  per100g: { kcal, proteinG, carbsG, fatG, sugarG?, fiberG?, saltG? },
  servingG?: number,         // only 15% of OFF products have one
  offScans?: number,
  ownerId?: string,          // set for "custom" foods, which are private
}
// indexes: by_barcode, by_source_sourceId
// search index on searchText, filter fields: source, ownerId

logEntries: {
  userId: string,
  day: string,               // local date, "YYYY-MM-DD"
  meal: "breakfast" | "lunch" | "dinner" | "snack",
  loggedAt: number,
  foodId?: Id<"foods">,      // absent for AI-estimated items
  name: string,              // snapshot
  brand?: string,            // snapshot
  grams: number,
  per100g: { ... },          // snapshot, so refreshes never change history
  origin: "search" | "recent" | "barcode" | "photo" | "text" | "copy",
  estimated: boolean,        // true when values came from the model, not a database food
}
// indexes: by_user_day

recentFoods: {
  userId: string,
  foodId: Id<"foods">,
  lastUsedAt: number,
  useCount: number,
  lastGrams: number,
}
// indexes: by_user_lastUsed, by_user_food

aiUsage: {
  userId: string,
  day: string,
  kind: "photo" | "text" | "label",
  model: string,
  inputTokens: number,
  outputTokens: number,
  ok: boolean,
}
// indexes: by_user_day, by_day
```

Rules:

- A log entry's calories are computed from `grams` and its `per100g` snapshot.
- Sugar, fibre and salt stay optional everywhere; fibre is present on only 44% of OFF products.
- Every user-owned table (`logEntries`, `recentFoods`, `aiUsage`, and `custom` foods) joins
  `profile:transferOnLink` with merge semantics, since it also runs when the Apple account already
  exists. `recentFoods` merges by food, keeping the latest date and summing use counts.

## Search

Normalisation runs on both stored text and queries, in `convex/lib/foodSearch.ts`:

1. Lowercase, strip accents, and replace non-alphanumerics with spaces.
2. Strip a trailing `s` or `x` from tokens of 4 or more characters.
3. Keep at most 16 terms, the Convex query limit.

Tested on a 10k sample in the dev deployment: "pâtes" returned nothing while "pates" matched;
"yaourt" and "yaourts" returned different results; and "yaourt nat" ranked a "Nat &form" tea
first, because one matching word is enough.

Each search fetches 200 public foods, 50 CIQUAL foods in a separate search, and the user's own
`custom` foods. Tested on the full data: a fetch of 50 returned only 21 exact matches for "pâtes",
and no CIQUAL food reached the top 200 for "riz". Prefix matching on the last word causes the first,
and the 620,000 products crowding out 3,400 generic foods cause the second.

Ranking, in `foodSearch.ts` as a pure function:

1. Foods from the user's `recentFoods`.
2. Results with every query term as a whole word.
3. Results matching every term, with the last as a prefix.
4. The rest.

Within each group, names containing the words as typed, before plural stripping, come first, and
names starting with them lead those. "Pâtes" and "pâté" share the stem `pate`, but "pates" is only
a word in the first, so pasta comes before pâté, and "Riz blanc" before "Farine de riz".

Ties go to CIQUAL foods, since that is usually what someone logging home-cooked food wants. Then
come products with `offScans >= 20`, most scanned first, then the rest in Convex's order. Blank
counts are never penalised. Results are limited to public foods plus the user's own `custom`
foods. The client waits 250 ms after typing before querying.

Convex search has no typo tolerance; this is accepted, and recents reduce how often it matters.

## Phase 1: Logging core

Day view:

- `DayPage` subscribes to `logs:forDay`, replacing the meals half of `MockDayLogs`.
- Each meal is one row with its kcal, a preview of its foods and an add button, and
  `TargetsCard` receives real totals.
- Tapping a meal opens its page: a recap of kcal and macros, with their share of the day's targets
  when there's a profile, then its foods. Foods live here rather than on the day view so that
  swipe to delete doesn't compete with swiping between days.

Add sheet, opened from a meal:

- Search field, with recents shown before typing.
- Scan, Photo and Describe buttons, added as phases 2 and 3 land.
- Selecting a food opens an amount screen: grams first, with quick chips, plus one serving when
  `servingG` is known. Grams default to the user's `lastGrams` for that food.

Speed features:

- **Repeat:** re-add a past entry from recents with its last amount.
- **Copy yesterday:** copy a meal from the previous day.
- **Custom food:** create a private food by hand when nothing matches.

Editing: on the meal page, entries can be changed or deleted by tap, or deleted by swipe.

Credit Open Food Facts and CIQUAL with links on an About screen, as ODbL requires for public use.

## Phase 2: Barcode

Scanning uses VisionKit's `DataScannerViewController`, on device with no fee. It needs
`NSCameraUsageDescription`.

Lookup, in a Convex action:

1. Query `foods` by barcode, preferring `label` over `off`.
2. If missing, call OFF once with a custom User-Agent. The value comes from the
   `OFF_USER_AGENT` Convex env var, as OFF requires an identifying name and contact.
3. Apply rules 2–6. If they pass, save as `off` for everyone.
4. If it fails or is not found, offer the label photo.

Label photo: the model reads the label into the same fields, rules 2–6 apply, the user confirms,
and the food is saved as `label` for everyone. OFF allows 15 product reads/min per IP, and all
Convex calls probably share an IP. That is fine for friends; going public may need device-side
lookups.

## Phase 3: AI logging

Fixed pipeline, not a full agent loop. It is faster, predictable and testable. Only the
item-level retry lets the model choose its next search.

Input is a photo, resized on device to about 1,000 px and uploaded to Convex storage, or text. The
stored photo is deleted when the action finishes, whether it succeeded or not.

1. **Identify** (vision or text call, structured output). For each item: `label`, `kind`
   (`generic` or `branded`), `searchTerms` (2–3 French phrases), `brand?`, `grams`, and
   `estimatePer100g`.
2. **Candidates** (code). Run each search term, generic items searching `ciqual` first and branded
   items searching `off` first. User recents come first. Keep about 5 deduplicated candidates.
3. **Pick** (text call, structured output restricted to the candidate ids or `none`).
4. **Retry** (only for `none`). A small loop on that item alone, with at most 2 more searches.
5. **Plausibility** (code). Reject a pick if its kcal differs from `estimatePer100g` by more than
   40%, and use the estimate with `estimated: true`.
6. **Review** (client). Each row shows name, grams and source (CIQUAL, the brand, or Estimated).
   The user can change grams, swap candidate, search, delete, or type a correction such as "half
   a portion, no sauce". Nothing is saved until confirmed.

Text input skips the image and uses the same steps. A correction re-runs the call with the draft
and the user's text, then repeats steps 2–5 for changed items.

Model choice: the model id is the `AI_MODEL` Convex env var. Before phase 3 ships, run about 30
real meal photos through Haiku 5.5 and Sonnet 5.5, scoring food match and grams separately. Keep
Haiku if it holds up; if not, add a "try harder" retry on Sonnet.

| Model | Per log (estimate) | 900 logs/month (estimate) |
|---|---|---|
| Haiku 5.5 | ~$0.001 | ~$1 |
| Sonnet 5.5 | ~$0.02 | ~$20 |
| Opus 5.5 | ~$0.05 | ~$45 |

Portion size stays the largest error in photo logging. Matching corrects what the food is, not how
much of it there is, so grams are the easiest field to change on the review screen.

Cost controls:

- Per-user limits: 30 AI logs/day for signed-in users, 5/day for guests.
- A global limit of 300 AI logs/day, checked against `aiUsage`.
- A monthly spend limit set in the Anthropic Console.

The API key lives in the `ANTHROPIC_API_KEY` Convex env var and never reaches the app.

## Error handling

| Case | Behaviour |
|---|---|
| OFF down or rate limited | Barcode falls through to the label photo; search is unaffected |
| Barcode unknown | Offer label photo or manual search |
| Model call fails | Show the error and keep the input so the user can retry; no entry is written |
| Model refuses or returns no items | Say nothing was recognised and offer search |
| AI limit reached | Explain the limit; search and barcode keep working |
| Photo upload fails | Retry once, then show the error |
| Pick fails but identify worked | Show the items as Estimated |
| Offline | Adding fails with a connection message; offline logging is out of scope |

## Testing

- **Pure functions, with vitest:** food quality rules, CIQUAL value parsing, normalisation, ranking
  and plausibility, using real rejected and rescued examples from the measurement.
- **Convex functions, with convex-test:** log entry ownership, `forDay`, recents, transfer on link
  with merge, usage limits.
- **AI pipeline:** model calls behind a small interface so the pipeline runs on recorded responses.
  Real calls only happen in the evaluation script.
- **iOS:** manual pass through each flow on a device, since the scanner needs a real camera.

## Unknowns to resolve in phase 1

- **Real Convex storage:** raw data is 280 bytes per document, or 173 MB for 619,653 products, and
  an estimated 250 MB with indexes against the 0.5 GB free limit. The CLI does not report storage.
  The full import must be checked on the dashboard before phase 1 is called done.
- **Import bandwidth:** the free tier has 1 GB/month of database bandwidth. One full import may use
  about a fifth of it if writes count. If the free tier does not hold, raise the rule 7 threshold
  or move to pay-as-you-go, where overages are cheap.
- **Import time:** the sample took 6.4 s for 10,000 documents, which suggests about 7 minutes.

## Going public later

- ODbL requires attribution and share-alike on public adapted databases. OFF rows are kept
  identifiable through `source`, but `label` foods derived alongside them need a licence check first.
- Account deletion (App Store guideline 5.1.1(v)) must cover all user-owned tables here.
- Guest cleanup must remove the same tables.
