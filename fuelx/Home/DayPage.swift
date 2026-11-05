import Combine
import ConvexMobile
import SwiftUI

/// One day's numbers: summary, targets, meals, and workouts.
struct DayPage: View {
    let day: Date
    let onSetUpProfile: () -> Void

    /// `nil` until the first result arrives; `.some(nil)` when there's no profile yet.
    @State private var targets: NutritionTargets??
    /// `nil` until the first result arrives; `.some(nil)` when signed out.
    @State private var dayEntries: DayEntries??
    @State private var workoutDay: WorkoutDay?
    @State private var addingTo: MealKind?

    private var loadedEntries: DayEntries? { dayEntries ?? nil }

    private var log: DayLog {
        DayLog(
            day: day,
            mealCalories: Int(loadedEntries?.totals.kcal ?? 0),
            workouts: workoutDay?.workouts ?? [],
            steps: workoutDay?.steps.map(Int.init))
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
                if !HealthSync.shared.isConnected {
                    Button("Connect Apple Health", systemImage: "heart") {
                        Task { await HealthSync.shared.connect() }
                    }
                } else if log.workouts.isEmpty {
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
                with: NutritionTargets.queryArgs(for: day),
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
        .task(id: day) {
            let updates = convex.subscribe(
                to: "workouts:forDay",
                with: ["day": Days.key(for: day)],
                yielding: WorkoutDay?.self)
            do {
                for try await value in updates.values { workoutDay = value }
            } catch {
                print("workouts:forDay failed: \(error)")
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
                TargetsCard(targets: targets, caloriesEaten: log.mealCalories, eaten: loadedEntries?.totals)
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
                    stat("Eaten", log.mealCalories.kcal, systemImage: "fork.knife")
                    stat("Burned", log.caloriesBurned.kcal, systemImage: "flame")
                    if let steps = log.steps {
                        stat("Steps", steps.formatted(), systemImage: "figure.walk")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
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
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title)
                    Text(workout.detail)
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
        .padding(.vertical, 2)
    }
}

#Preview {
    DayPage(day: Days.today, onSetUpProfile: {})
}
