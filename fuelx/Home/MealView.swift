import Combine
import ConvexMobile
import SwiftUI

/// Identifies a meal page in the navigation stack.
nonisolated struct MealRoute: Hashable, Sendable {
    let day: Date
    let meal: MealKind
}

/// One meal: a recap of what it adds up to, then its foods.
struct MealView: View {
    let day: Date
    let meal: MealKind

    /// `nil` until the first result arrives, or without a profile.
    @State private var targets: NutritionTargets?
    /// `nil` until the first result arrives; `.some(nil)` when signed out.
    @State private var dayEntries: DayEntries??
    @State private var isAdding = false
    @State private var editing: LogEntry?
    @State private var isCopying = false
    @State private var isConfirmingCopy = false
    @State private var alertMessage: String?

    private var loadedEntries: DayEntries? { dayEntries ?? nil }
    private var entries: [LogEntry] { loadedEntries?.entries(for: meal) ?? [] }

    var body: some View {
        List {
            if let totals = loadedEntries?.mealTotals[meal], !entries.isEmpty {
                Section {
                    MealRecap(totals: totals, targets: targets)
                }
                Section("Foods") {
                    ForEach(entries) { entry in
                        Button { editing = entry } label: { LogEntryRow(entry: entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(entry)
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if loadedEntries != nil, entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Logged", systemImage: meal.systemImage)
                } actions: {
                    Button("Add Food") { isAdding = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(meal.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy from Yesterday", systemImage: "doc.on.doc", action: requestCopy)
                        .disabled(isCopying)
                }
                Button("Add Food", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddFoodSheet(day: day, meal: meal)
        }
        .sheet(item: $editing) { entry in
            NavigationStack {
                AmountView(
                    food: entry.food,
                    initialGrams: entry.grams,
                    primaryTitle: "Save",
                    onDelete: {
                        try await convex.mutation("logs:remove", with: ["id": entry.id])
                        editing = nil
                    }
                ) { grams in
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
            isPresented: $isConfirmingCopy,
            titleVisibility: .visible
        ) {
            Button("Copy Anyway", action: copyFromYesterday)
        } message: {
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
                for try await value in updates.values { targets = value }
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
    private func requestCopy() {
        if entries.isEmpty {
            copyFromYesterday()
        } else {
            isConfirmingCopy = true
        }
    }

    private func copyFromYesterday() {
        guard let yesterday = Days.calendar.date(byAdding: .day, value: -1, to: day) else { return }
        isCopying = true
        Task {
            defer { isCopying = false }
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
}

/// What a meal adds up to and, with a profile, how much of the day's targets that is.
private struct MealRecap: View {
    let totals: NutritionTotals
    let targets: NutritionTargets?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Int(totals.kcal).formatted())
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text("kcal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if let share = share(of: totals.kcal, target: targets?.calories) {
                    Text("\(share) of your day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top) {
                macro("Protein", grams: totals.proteinG, target: targets?.proteinG)
                macro("Carbs", grams: totals.carbsG, target: targets?.carbsG)
                macro("Fat", grams: totals.fatG, target: targets?.fatG)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func macro(_ title: LocalizedStringKey, grams: Double, target: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(grams.grams)
                .font(.headline)
                .monospacedDigit()
            if let share = share(of: grams, target: target) {
                Text(share)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share(of value: Double, target: Double?) -> String? {
        guard let target, target > 0 else { return nil }
        return (value / target).formatted(.percent.precision(.fractionLength(0)))
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
