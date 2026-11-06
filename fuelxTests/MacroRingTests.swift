import Testing

@testable import fuelx

struct MacroRingTests {
    private func totals(kcal: Double = 500, carbs: Double, protein: Double, fat: Double) -> NutritionTotals {
        NutritionTotals(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat)
    }

    @Test func splitsByCaloriesNotGrams() {
        // 25 g of each: fat counts for 9 kcal per gram, the others for 4.
        let segments = MacroRingSegment.segments(totals(carbs: 25, protein: 25, fat: 25))
        #expect(segments.map(\.macro) == [.carbs, .protein, .fat])
        #expect(abs(segments[2].end - segments[2].start - 9.0 / 17) < 0.0001)
    }

    @Test func coversTheWholeRing() throws {
        let segments = MacroRingSegment.segments(totals(carbs: 98, protein: 67, fat: 28))
        #expect(segments.first?.start == 0)
        #expect(abs(try #require(segments.last).end - 1) < 0.0001)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func dropsSpecksAndClosesTheGap() throws {
        // Fat is 2% of these calories.
        let segments = MacroRingSegment.segments(totals(carbs: 70, protein: 31, fat: 1))
        #expect(segments.map(\.macro) == [.carbs, .protein])
        #expect(abs(try #require(segments.last).end - 1) < 0.0001)
    }

    @Test func foodWithoutMacrosFillsTheRing() throws {
        let segments = MacroRingSegment.segments(totals(carbs: 0, protein: 0, fat: 0))
        #expect(segments.count == 1)
        #expect(try #require(segments.first).macro == nil)
        #expect(MacroRingSegment.accessibilityLabel(for: segments).isEmpty)
    }

    @Test func nothingEatenLeavesTheRingEmpty() {
        #expect(MacroRingSegment.segments(totals(kcal: 0, carbs: 0, protein: 0, fat: 0)).isEmpty)
    }
}
