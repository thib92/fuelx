import SwiftUI

/// A closed ring showing how calories split between carbs, protein and fat. `center` sits inside.
struct MacroRing<Center: View>: View {
    let segments: [MacroRingSegment]
    let lineWidth: CGFloat
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemFill), lineWidth: lineWidth)
            ForEach(segments) { segment in
                // Each runs slightly under the next, so no seam shows.
                Circle()
                    .trim(from: segment.start, to: min(segment.end + 0.002, 1))
                    .stroke(segment.color, lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(lineWidth / 2)
        .animation(.snappy, value: segments)
    }
}

/// One colored stretch of a `MacroRing`, in fractions of the ring.
struct MacroRingSegment: Identifiable, Equatable {
    let id: Int
    let start: CGFloat
    let end: CGFloat
    let color: Color
    /// Set unless the food has calories but no macros.
    var macro: Macro?

    /// Below this share a macro is only a speck, so the others take its place.
    private static var minimumShare: Double { 0.04 }

    /// Splits the ring by each macro's calories. Food without macros fills it in the tint color.
    static func segments(_ totals: NutritionTotals) -> [MacroRingSegment] {
        let parts = Macro.allCases.map { (macro: $0, kcal: totals.grams(of: $0) * $0.kcalPerGram) }
        let total = parts.reduce(0) { $0 + $1.kcal }
        guard total > 0 else {
            guard totals.kcal > 0 else { return [] }
            return [MacroRingSegment(id: 0, start: 0, end: 1, color: .accentColor)]
        }

        let shown = parts.filter { $0.kcal / total >= minimumShare }
        let shownTotal = shown.reduce(0) { $0 + $1.kcal }
        var result: [MacroRingSegment] = []
        var start: CGFloat = 0
        for part in shown {
            let length = part.kcal / shownTotal
            result.append(MacroRingSegment(
                id: result.count, start: start, end: start + length, color: part.macro.color,
                macro: part.macro))
            start += length
        }
        return result
    }

    /// "Carbs 43%, Protein 29%, Fat 28%"
    static func accessibilityLabel(for segments: [MacroRingSegment]) -> String {
        segments
            .compactMap { segment in
                segment.macro.map { macro in
                    let share = Double(segment.end - segment.start)
                    return "\(macro.label) \(share.formatted(.percent.precision(.fractionLength(0))))"
                }
            }
            .joined(separator: ", ")
    }
}

extension NutritionTotals {
    func grams(of macro: Macro) -> Double {
        switch macro {
        case .carbs: carbsG
        case .protein: proteinG
        case .fat: fatG
        }
    }
}

extension NutritionTargets {
    func grams(of macro: Macro) -> Double {
        switch macro {
        case .carbs: carbsG
        case .protein: proteinG
        case .fat: fatG
        }
    }
}

extension LogEntry {
    var totals: NutritionTotals {
        NutritionTotals(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }
}
