# Meal logging phase 2: barcode

**Goal:** Scan a product barcode from the add sheet, find the food, and log it.

**Spec:** "Phase 2: Barcode" in `docs/superpowers/specs/2026-11-05-meal-logging-design.md`.

**Scope change from the spec:** the label photo is deferred to phase 3, which adds the model
pipeline it needs. Until then, a product that can't be found offers a rescan or manual search.

## Decisions

- The lookup is one Convex action, `foods:lookupBarcode`, returning `found`, `notFound` or
  `unavailable`, so Swift holds no lookup rules.
- OFF answers HTTP 404 for an unknown product. That is `notFound`, not an outage. Other failures,
  timeouts and a missing `OFF_USER_AGENT` are `unavailable`, and logged.
- A product failing rules 2-6 is `notFound`. Nothing is saved, so the next scan asks OFF again.
- No barcode normalisation. iOS reports UPC-A as 13 digits with a leading 0, which matches the
  import (30,861 such codes, and only 2 of 12 digits).
- The scanner reads EAN-13 and EAN-8 only. UPC-E is left out because it isn't a full code and is
  rare in France.
- Rule 7 stays in the bulk import. `offDoc` in `convex/lib/offProduct.ts` applies rules 2-6 and
  `offFood` in `scripts/foods/mapping.ts` adds rule 7 on top.

## Tasks

### Task 1: Share the OFF mapping

- Move `OffRow` and the rules 2-6 mapping from `scripts/foods/mapping.ts` to
  `convex/lib/offProduct.ts`, and `roundPer100g` to `convex/lib/foodQuality.ts`.
- Add `offRowFromApi` and `fetchOffRow`, and export `isValidBarcode`.
- Tests: the OFF API shape maps to the import shape, string values parse, and products failing
  rules 2-6 are rejected while rule 7 is not applied.

### Task 2: Lookup action

- Add `foods:lookupBarcode`, internal `foods:byBarcode` and internal `foods:saveOffFood`.
- Accept `barcode` as an origin in `logs:add`.
- Tests: `label` wins over `off`, a known food makes no OFF call, a good product is saved once,
  404, 500, a network failure and a missing User-Agent map to the right status, and signed-out
  callers are refused.

### Task 3: iOS

- Add `NSCameraUsageDescription` through the generated Info.plist.
- Add `BarcodeScannerView` (VisionKit) and `ScanView` (permission, lookup and failure states).
- Add a scan button to `AddFoodSheet`, which opens the amount screen with origin `barcode`.

### Task 4: Finish

- Run `npm test`, `npx tsc --noEmit -p convex` and the Xcode build.
- Set `OFF_USER_AGENT` on the Convex deployment and do the manual pass on a device: a known
  product, a product only on OFF, an unknown code, camera denied, and offline.
