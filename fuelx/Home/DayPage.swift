import SwiftUI

/// One day's numbers: summary, meals, and workouts with the fuel taken during them.
struct DayPage: View {
    let log: DayLog

    var body: some View {
        List {
            Section {
                DaySummary(log: log)
            }

            if log.isEmpty {
                ContentUnavailableView(
                    "Nothing Logged",
                    systemImage: "fork.knife",
                    description: Text("Meals, workouts and fuel for this day will show up here."))
            } else {
                Section {
                    ForEach(log.meals) { MealRow(meal: $0) }
                } header: {
                    SectionHeader(title: "Meals", value: log.mealCalories.kcal)
                }

                Section {
                    if log.workouts.isEmpty {
                        Label("Rest day", systemImage: "bed.double")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(log.workouts) { WorkoutRow(workout: $0) }
                } header: {
                    SectionHeader(
                        title: "Workouts",
                        value: log.workouts.isEmpty ? nil : "−\(log.caloriesBurned.kcal)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let value: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let value {
                Text(value).monospacedDigit()
            }
        }
    }
}

struct DaySummary: View {
    let log: DayLog

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Net")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(log.netCalories.formatted())
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text("kcal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    stat("Eaten", log.caloriesIn, systemImage: "fork.knife")
                    stat("Burned", log.caloriesBurned, systemImage: "flame")
                }
                GridRow {
                    Text("Meals \(log.mealCalories.formatted()) · Fuel \(log.fuelCalories.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: LocalizedStringKey, _ value: Int, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value.kcal)
                .font(.headline)
                .monospacedDigit()
        }
    }
}

private struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.kind.rawValue)
                    Text(meal.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: meal.kind.systemImage)
            }
            Spacer()
            Text(meal.calories.kcal)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.title)
                        Text("\(workout.sport.rawValue) · \(workout.duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: workout.sport.systemImage)
                }
                Spacer()
                Text("−\(workout.caloriesBurned.kcal)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !workout.fuel.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Fuel")
                        Spacer()
                        Text("+\(workout.fuelCalories.kcal)").monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ForEach(workout.fuel) { item in
                        HStack {
                            Image(systemName: "drop.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                            Text(item.name)
                            Spacer()
                            Text(item.time.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                            Text(item.calories.kcal)
                                .monospacedDigit()
                                .frame(minWidth: 70, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DayPage(log: MockDayLogs.log(for: Days.today.addingTimeInterval(-86_400)))
}
