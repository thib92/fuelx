import SwiftUI

/// How the day's target adds up, and the notes behind it.
struct TargetDetailsSheet: View {
    let targets: NutritionTargets
    let workouts: [Workout]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Maintenance", Int(targets.maintenanceCalories).kcal)
                    if targets.goalAdjustment != 0 {
                        row(
                            targets.goalAdjustment < 0 ? "Weight loss" : "Weight gain",
                            signed(Int(targets.goalAdjustment)))
                    }
                    ForEach(workouts) { workout in
                        row(LocalizedStringKey(workout.title), signed(workout.caloriesBurned))
                    }
                    LabeledContent("Target", value: Int(targets.calories).kcal)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                Section {
                    row(
                        LocalizedStringKey(Macro.carbs.label),
                        "\(Int(targets.carbsG)) g · \(targets.carbsGPerKg.formatted(.number.precision(.fractionLength(1)))) g/kg")
                    row(LocalizedStringKey(Macro.protein.label), "\(Int(targets.proteinG)) g")
                    row(LocalizedStringKey(Macro.fat.label), "\(Int(targets.fatG)) g")
                } footer: {
                    if !notes.isEmpty {
                        Text(notes.joined(separator: " "))
                    }
                }
            }
            .navigationTitle("Daily Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .monospacedDigit()
    }

    private func signed(_ kcal: Int) -> String {
        kcal < 0 ? "−\((-kcal).kcal)" : "+\(kcal.kcal)"
    }

    private var notes: [String] {
        [
            targets.workoutCalories > 0
                ? String(localized: "Workout calories go to carbs, up to 12 g/kg, then to fat.") : nil,
            targets.stepsUsed.map { String(localized: "Everyday activity is based on \(Int($0).formatted()) steps, not counting runs and walks.") },
            targets.goalRateCapped ? String(localized: "Weight loss is capped at 1% of body weight per week.") : nil,
            targets.calorieFloorApplied ? String(localized: "Raised to your resting energy: eating less isn't recommended.") : nil,
            targets.lowCarbs ? String(localized: "Carbs are below 3 g/kg, the low end for athletes.") : nil,
        ].compactMap(\.self)
    }
}
