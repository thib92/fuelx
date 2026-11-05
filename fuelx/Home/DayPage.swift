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
    @State private var editing: LogEntry?
    @State private var copying: Set<MealKind> = []
    @State private var confirmingCopy: MealKind?
    @State private var alertMessage: String?

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

            ForEach(MealKind.allCases) { meal in
                mealSection(meal)
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
        .sheet(item: $editing) { entry in
            NavigationStack {
                AmountView(food: entry.food, initialGrams: entry.grams, primaryTitle: "Save") { grams in
                    try await convex.mutation("logs:update", with: ["id": entry.id, "grams": grams])
                    editing = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { editing = nil }
                    }
                }
            }
        }
        .confirmationDialog(
            "This meal already has food.",
            isPresented: Binding(get: { confirmingCopy != nil }, set: { if !$0 { confirmingCopy = nil } }),
            titleVisibility: .visible,
            presenting: confirmingCopy
        ) { meal in
            Button("Copy Anyway") { copyFromYesterday(meal) }
        } message: { _ in
            Text("Yesterday's food will be added to what's already logged.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
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

    private func mealSection(_ meal: MealKind) -> some View {
        let entries = loadedEntries?.entries(for: meal) ?? []
        let totals = loadedEntries?.mealTotals[meal]
        return Section {
            ForEach(entries) { entry in
                Button { editing = entry } label: { LogEntryRow(entry: entry) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
                    }
            }
            HStack {
                Button("Add Food", systemImage: "plus") { addingTo = meal }
                    .buttonStyle(.borderless)
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy from Yesterday", systemImage: "doc.on.doc") { requestCopy(meal) }
                        .disabled(copying.contains(meal))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        } header: {
            SectionHeader(
                title: Text(meal.label),
                value: entries.isEmpty ? nil : Int(totals?.kcal ?? 0).kcal)
        } footer: {
            if let totals, !entries.isEmpty {
                Text("Protein \(totals.proteinG.grams) · Carbs \(totals.carbsG.grams) · Fat \(totals.fatG.grams)")
                    .monospacedDigit()
            }
        }
    }

    private func delete(_ entry: LogEntry) {
        Task {
            do {
                try await ConnectionMonitor.shared.ensureConnected()
                try await convex.mutation("logs:remove", with: ["id": entry.id])
            } catch {
                alertMessage = error.convexMessage
            }
        }
    }

    /// The backend adds to a meal that already has food, so a repeat copy would double it.
    private func requestCopy(_ meal: MealKind) {
        if loadedEntries?.entries(for: meal).isEmpty == false {
            confirmingCopy = meal
        } else {
            copyFromYesterday(meal)
        }
    }

    private func copyFromYesterday(_ meal: MealKind) {
        guard let yesterday = Days.calendar.date(byAdding: .day, value: -1, to: day) else { return }
        copying.insert(meal)
        Task {
            defer { copying.remove(meal) }
            do {
                try await ConnectionMonitor.shared.ensureConnected()
                let count: Double = try await convex.mutation("logs:copyMeal", with: [
                    "fromDay": Days.key(for: yesterday),
                    "toDay": Days.key(for: day),
                    "meal": meal.rawValue,
                ])
                if count == 0 {
                    alertMessage = String(localized: "Nothing to copy.")
                }
            } catch {
                alertMessage = error.convexMessage
            }
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

private struct LogEntryRow: View {
    let entry: LogEntry

    private var detail: String {
        [entry.brand, entry.grams.grams, entry.estimated ? String(localized: "Estimated") : nil]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Int(entry.kcal).kcal)
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
    DayPage(day: Days.today, workouts: MockDayLogs.workouts(for: Days.today), onSetUpProfile: {})
}
