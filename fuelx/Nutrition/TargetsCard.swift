import SwiftUI

/// Calories eaten against the day's target, plus macro targets.
struct TargetsCard: View {
    let targets: NutritionTargets
    let caloriesEaten: Int
    /// Macros from logged entries.
    var eaten: NutritionTotals?

    private var target: Int { Int(targets.calories) }
    private var remaining: Int { target - caloriesEaten }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(caloriesEaten.formatted()) of \(target.kcal)")
                        .font(.headline)
                        .monospacedDigit()
                }
                Spacer()
                Text(remaining >= 0 ? "\(remaining.formatted()) left" : "\((-remaining).formatted()) over")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(remaining >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }

            ProgressView(value: Double(min(caloriesEaten, target)), total: Double(max(target, 1)))
                .tint(remaining >= 0 ? nil : .orange)

            HStack(alignment: .top) {
                macro("Protein", grams: targets.proteinG, eaten: eaten?.proteinG)
                macro("Carbs", grams: targets.carbsG, eaten: eaten?.carbsG,
                      detail: "\(targets.carbsGPerKg.formatted(.number.precision(.fractionLength(1)))) g/kg")
                macro("Fat", grams: targets.fatG, eaten: eaten?.fatG)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func macro(
        _ title: LocalizedStringKey, grams: Double, eaten: Double?, detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(eaten.map { "\(Int($0)) of \(Int(grams)) g" } ?? "\(Int(grams)) g")
                .font(.headline)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explains adjustments behind the targets, shown under the card.
struct TargetsFootnote: View {
    let targets: NutritionTargets

    var body: some View {
        let notes = [
            String(localized: "Workouts aren't included yet."),
            targets.stepsUsed.map { String(localized: "Everyday activity is based on \(Int($0).formatted()) steps, not counting runs and walks.") },
            targets.goalAdjustment == 0 ? nil
                : targets.goalAdjustment < 0
                ? String(localized: "Includes \(Int(-targets.goalAdjustment)) kcal less per day for weight loss.")
                : String(localized: "Includes \(Int(targets.goalAdjustment)) kcal more per day for weight gain."),
            targets.goalRateCapped ? String(localized: "Weight loss is capped at 1% of body weight per week.") : nil,
            targets.calorieFloorApplied ? String(localized: "Raised to your resting energy: eating less isn't recommended.") : nil,
            targets.lowCarbs ? String(localized: "Carbs are below 3 g/kg, the low end for athletes.") : nil,
        ].compactMap(\.self)

        Text(notes.joined(separator: " "))
    }
}
