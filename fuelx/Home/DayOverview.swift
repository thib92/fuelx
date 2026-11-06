import SwiftUI

/// The top of the day: calories as a ring, macros below it.
struct DayOverview: View {
    let targets: NutritionTargets
    let eaten: NutritionTotals?
    /// Past days show what was eaten rather than what's left.
    let isToday: Bool
    let onShowDetails: () -> Void

    private var caloriesEaten: Int { Int(eaten?.kcal ?? 0) }
    private var target: Int { Int(targets.calories) }
    private var workoutCalories: Int { Int(targets.workoutCalories) }
    private var remaining: Int { target - caloriesEaten }

    var body: some View {
        VStack(spacing: 14) {
            CalorieRing(arcs: arcs) {
                center
            } caption: {
                Button(action: onShowDetails) {
                    HStack(spacing: 4) {
                        Text(targetLine)
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows how this target is set")
            }

            HStack(alignment: .top, spacing: 16) {
                macro(.carbs, eaten: eaten?.carbsG, target: targets.carbsG)
                macro(.protein, eaten: eaten?.proteinG, target: targets.proteinG)
                macro(.fat, eaten: eaten?.fatG, target: targets.fatG)
            }
        }
    }

    private var targetLine: String {
        guard workoutCalories > 0 else { return String(localized: "of \(target.kcal)") }
        let base = target - workoutCalories
        return String(localized: "of \(base.formatted()) + \(workoutCalories.kcal)")
    }

    @ViewBuilder
    private var center: some View {
        if isToday {
            centerText(abs(remaining), remaining >= 0 ? "kcal left" : "kcal over", isOver: remaining < 0)
        } else {
            centerText(caloriesEaten, "kcal eaten", isOver: false)
        }
    }

    private func centerText(_ value: Int, _ label: LocalizedStringKey, isOver: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value.formatted())
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .foregroundStyle(isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private var arcs: [CalorieRingArc] {
        CalorieRingArc.arcs(
            eaten: Double(caloriesEaten),
            target: targets.calories,
            macros: [
                (Macro.carbs.color, (eaten?.carbsG ?? 0) * Macro.carbs.kcalPerGram),
                (Macro.protein.color, (eaten?.proteinG ?? 0) * Macro.protein.kcalPerGram),
                (Macro.fat.color, (eaten?.fatG ?? 0) * Macro.fat.kcalPerGram),
            ])
    }

    private func macro(_ macro: Macro, eaten: Double?, target: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(macro.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ProgressView(value: min(eaten ?? 0, target), total: max(target, 1))
                .tint(macro.color)
            HStack(spacing: 4) {
                Text(Int(eaten ?? 0).formatted())
                    .fontWeight(.semibold)
                Text("/ \(Int(target).formatted()) g")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The macros, in the order the day shows them.
enum Macro: CaseIterable {
    case carbs, protein, fat

    var label: String {
        switch self {
        case .carbs: String(localized: "Carbs")
        case .protein: String(localized: "Protein")
        case .fat: String(localized: "Fat")
        }
    }

    var color: Color {
        switch self {
        case .carbs: Color(red: 1, green: 0.77, blue: 0.24)
        case .protein: .blue
        case .fat: Color(red: 0.9, green: 0.44, blue: 0.76)
        }
    }

    var kcalPerGram: Double {
        switch self {
        case .carbs, .protein: 4
        case .fat: 9
        }
    }
}

/// An open ring, filled with one arc per macro. `center` sits inside it and `caption` in the gap
/// at the bottom.
struct CalorieRing<Center: View, Caption: View>: View {
    let arcs: [CalorieRingArc]
    @ViewBuilder let center: Center
    @ViewBuilder let caption: Caption

    private static var lineWidth: CGFloat { 14 }
    /// The ring's share of a full circle.
    private static var sweep: CGFloat { 0.75 }

    var body: some View {
        VStack(spacing: -22) {
            ZStack {
                ring(from: 0, to: 1, color: Color(.systemFill), lineCap: .round)
                // Square arcs over round ones: neighbors meet flat, and only the fill's outer
                // ends stay round. Each runs slightly under the next, so no seam shows.
                ForEach(arcs) { ring(from: $0.start, to: $0.end, color: $0.color, lineCap: .round) }
                ForEach(arcs) {
                    ring(from: $0.start, to: min($0.end + 0.002, 1), color: $0.color, lineCap: .butt)
                }
                center
            }
            .frame(width: 200, height: 200)
            .padding(Self.lineWidth / 2)
            caption
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: arcs)
    }

    private func ring(from: CGFloat, to: CGFloat, color: Color, lineCap: CGLineCap) -> some View {
        Circle()
            .trim(from: from * Self.sweep, to: to * Self.sweep)
            .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: lineCap))
            .rotationEffect(.degrees(135))
    }
}

/// One colored stretch of a `CalorieRing`, in fractions of the ring.
struct CalorieRingArc: Identifiable, Equatable {
    let id: Int
    let start: CGFloat
    let end: CGFloat
    let color: Color

    /// The shortest stretch that still reads as "over".
    private static var minimumOverage: CGFloat { 0.07 }

    /// Fills the ring to `eaten / target`, split by each macro's share. Macros rarely add up to
    /// the calories exactly, so their shares are used rather than their values. Food without
    /// macros fills the ring in the tint color.
    static func arcs(
        eaten: Double, target: Double, macros: [(color: Color, kcal: Double)]
    ) -> [CalorieRingArc] {
        guard eaten > 0, target > 0 else { return [] }
        let filled = min(eaten / target, 1)
        let macroKcal = macros.reduce(0) { $0 + $1.kcal }
        let parts = macroKcal > 0 ? macros : [(color: Color.accentColor, kcal: 1)]
        let partsKcal = parts.reduce(0) { $0 + $1.kcal }

        var result: [CalorieRingArc] = []
        var start: CGFloat = 0
        for part in parts where part.kcal > 0 {
            let length = filled * part.kcal / partsKcal
            result.append(CalorieRingArc(id: result.count, start: start, end: start + length, color: part.color))
            start += length
        }
        if eaten > target {
            let length = max(min((eaten - target) / target, 1), minimumOverage)
            result.append(CalorieRingArc(id: result.count, start: 1 - length, end: 1, color: .red))
        }
        return result
    }
}
