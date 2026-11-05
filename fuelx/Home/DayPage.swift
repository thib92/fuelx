import Combine
import ConvexMobile
import SwiftUI

/// One day's numbers: summary, targets, meals, and workouts with the fuel taken during them.
struct DayPage: View {
    let day: Date
    let workouts: [Workout]
    let onSetUpProfile: () -> Void

    /// `nil` until the first result arrives; `.some(nil)` when there's no profile yet.
    @State private var targets: NutritionTargets??
    /// `nil` until the first result arrives; `.some(nil)` when signed out.
    @State private var dayEntries: DayEntries??
    @State private var addingTo: MealKind?

    private var loadedEntries: DayEntries? { dayEntries ?? nil }

    private var log: DayLog {
        DayLog(day: day, mealCalories: Int(loadedEntries?.totals.kcal ?? 0), workouts: workouts)
    }

    var body: some View {
        List {
            Section {
                DaySummary(log: log)
            }

            targetsSection

            Section("Meals") {
                ForEach(MealKind.allCases) { meal in
                    mealRow(meal)
                }
            }

            Section {
                if log.workouts.isEmpty {
                    Label("Rest day", systemImage: "bed.double")
                        .foregroundStyle(.secondary)
                }
                ForEach(log.workouts) { WorkoutRow(workout: $0) }
            } header: {
                SectionHeader(
                    title: Text("Workouts"),
                    value: log.workouts.isEmpty ? nil : "−\(log.caloriesBurned.kcal)")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $addingTo) { meal in
            AddFoodSheet(day: day, meal: meal)
        }
        .task(id: day) {
            let updates = convex.subscribe(
                to: "nutrition:targetsForDay",
                with: ["day": Days.key(for: day)],
                yielding: NutritionTargets?.self)
            do {
                for try await value in updates.values { targets = .some(value) }
            } catch {
                print("nutrition:targetsForDay failed: \(error)")
            }
        }
        .task(id: day) {
            let updates = convex.subscribe(
                to: "logs:forDay",
                with: ["day": Days.key(for: day)],
                yielding: DayEntries?.self)
            do {
                for try await value in updates.values { dayEntries = .some(value) }
            } catch {
                print("logs:forDay failed: \(error)")
            }
        }
    }

    private func mealRow(_ meal: MealKind) -> some View {
        HStack {
            NavigationLink(value: MealRoute(day: day, meal: meal)) {
                MealRow(
                    meal: meal,
                    entries: loadedEntries?.entries(for: meal) ?? [],
                    kcal: Int(loadedEntries?.mealTotals[meal].kcal ?? 0))
            }
            Button("Add Food to \(meal.label)", systemImage: "plus.circle.fill") { addingTo = meal }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var targetsSection: some View {
        switch targets {
        case .some(.some(let targets)):
            Section {
                TargetsCard(targets: targets, caloriesEaten: log.caloriesIn, eaten: loadedEntries?.totals)
            } header: {
                Text("Daily Targets")
            } footer: {
                TargetsFootnote(targets: targets)
            }
        case .some(.none):
            Section {
                Button(action: onSetUpProfile) {
                    Label("Set Up Your Daily Targets", systemImage: "target")
                }
            } footer: {
                Text("Get calorie, protein, carb and fat targets based on your body and goal.")
            }
        case .none:
            EmptyView()
        }
    }
}

private struct SectionHeader: View {
    let title: Text
    let value: String?

    var body: some View {
        HStack {
            title
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

/// A meal's calories and a preview of its foods.
private struct MealRow: View {
    let meal: MealKind
    let entries: [LogEntry]
    let kcal: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meal.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.label)
                    .font(.headline)
                Text(kcal.kcal)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !entries.isEmpty {
                    Text(entries.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
    DayPage(day: Days.today, workouts: MockDayLogs.workouts(for: Days.today), onSetUpProfile: {})
}
