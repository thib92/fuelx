import ConvexMobile
import SwiftUI

/// Identifies a meal page in the navigation stack.
nonisolated struct MealRoute: Hashable, Sendable {
    let day: Date
    let meal: MealKind
}

/// One meal: how it splits between macros and where that leaves the day, then its foods.
struct MealView: View {
    let day: Date
    let meal: MealKind

    @Environment(\.dayStore) private var store
    @State private var isAdding = false
    @State private var editing: LogEntry?
    @State private var isCopying = false
    @State private var isConfirmingCopy = false
    @State private var alertMessage: String?

    private var targets: NutritionTargets? { store.targets(for: day).loaded }
    private var dayEntries: DayEntries? { store[day].entries }
    private var entries: [LogEntry] { dayEntries?.entries(for: meal) ?? [] }
    private var isEmpty: Bool { dayEntries != nil && entries.isEmpty }
    private var yesterday: Date? { Days.calendar.date(byAdding: .day, value: -1, to: day) }
    private var yesterdayEntries: DayEntries? { yesterday.flatMap { store[$0].entries } }

    var body: some View {
        List {
            if let dayEntries {
                Section {
                    MealHero(
                        meal: entries.isEmpty ? nil : dayEntries.mealTotals[meal],
                        day: dayEntries.totals,
                        targets: targets,
                        isToday: Days.calendar.isDateInToday(day))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if isEmpty {
                emptySections
            } else if !entries.isEmpty {
                foodsSection
            }
        }
        .navigationTitle(meal.label)
        .navigationSubtitle(Days.title(for: day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy from Yesterday", systemImage: "doc.on.doc", action: requestCopy)
                        .disabled(isCopying)
                }
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
            .presentationDragIndicator(.visible)
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
        .task(id: day) { await store.watch(.day(day)) }
        .task(id: isEmpty ? yesterday : nil) {
            if isEmpty, let yesterday { await store.watch(.day(yesterday)) }
        }
    }

    private var foodsSection: some View {
        Section {
            ForEach(entries) { entry in
                Button { editing = entry } label: { LogEntryRow(entry: entry) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            delete(entry)
                        }
                    }
            }
            Button { isAdding = true } label: {
                HStack(spacing: 13) {
                    Image(systemName: "plus")
                        .font(.subheadline.bold())
                        .frame(width: 30, height: 30)
                        .background(.tint.opacity(0.2), in: .circle)
                        .padding(.leading, 1)
                    Text("Add Food")
                        .fontWeight(.medium)
                }
            }
        } header: {
            SectionTitle(title: "Foods", trailing: "kcal")
        }
    }

    @ViewBuilder
    private var emptySections: some View {
        Section {
            Button { isAdding = true } label: {
                Label("Add Food", systemImage: "plus")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(.all, 0)
            .listRowBackground(Color.clear)
        } header: {
            SectionTitle(title: "Nothing logged yet")
        }

        if let yesterdayEntries, !yesterdayEntries.entries(for: meal).isEmpty {
            Section {
                Button(action: requestCopy) {
                    CopyMealRow(
                        entries: yesterdayEntries.entries(for: meal),
                        kcal: Int(yesterdayEntries.mealTotals[meal].kcal))
                }
                .buttonStyle(.plain)
                .disabled(isCopying)
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
        guard let yesterday else { return }
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

/// A meal's macro split beside the macros against the day. An empty meal shows what's left to eat.
private struct MealHero: View {
    /// `nil` for a meal with nothing logged.
    let meal: NutritionTotals?
    let day: NutritionTotals
    let targets: NutritionTargets?
    /// Past days show what was eaten rather than what's left, as the day page does.
    let isToday: Bool

    private var segments: [MacroRingSegment] { meal.map { MacroRingSegment.segments($0) } ?? [] }

    var body: some View {
        HStack(spacing: 20) {
            MacroRing(segments: segments, lineWidth: 16) { center }
                .frame(width: 168, height: 168)
                .accessibilityElement(children: .combine)
                .accessibilityValue(MacroRingSegment.accessibilityLabel(for: segments))
            VStack(spacing: 14) {
                ForEach(Macro.allCases, id: \.self) { macro in
                    macroRow(macro)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var center: some View {
        if let meal {
            centerText(Int(meal.kcal), "kcal", size: 44, isOver: false)
        } else if isToday, let targets {
            let remaining = Int(targets.calories) - Int(day.kcal)
            centerText(abs(remaining), remaining >= 0 ? "kcal left" : "kcal over", size: 36, isOver: remaining < 0)
        } else {
            centerText(Int(day.kcal), "kcal eaten", size: 36, isOver: false)
        }
    }

    private func centerText(_ value: Int, _ label: LocalizedStringKey, size: CGFloat, isOver: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value.formatted())
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .foregroundStyle(isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    private func macroRow(_ macro: Macro) -> some View {
        let dayGrams = day.grams(of: macro)
        let mealGrams = meal?.grams(of: macro)
        let target = targets?.grams(of: macro)

        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(macro.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                value(mealGrams: mealGrams, dayGrams: dayGrams, target: target)
            }
            if let target, target > 0 {
                MacroBar(
                    earlier: (dayGrams - (mealGrams ?? 0)) / target,
                    meal: (mealGrams ?? 0) / target,
                    color: macro.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func value(mealGrams: Double?, dayGrams: Double, target: Double?) -> some View {
        let grams: Double
        var detail: Text?
        if let mealGrams {
            grams = mealGrams
            if let target, target > 0 {
                detail = Text((mealGrams / target).formatted(.percent.precision(.fractionLength(0))))
            }
        } else if let target, isToday {
            grams = max(target - dayGrams, 0)
            detail = Text("left")
        } else {
            grams = dayGrams
            detail = target.map { Text("/ \(Int($0).formatted()) g") }
        }

        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(grams.rounded().grams)
                .font(.subheadline.weight(.semibold))
            if let detail {
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// A macro against the day's target: dimmed for what was eaten elsewhere, solid for this meal.
private struct MacroBar: View {
    /// Shares of the target.
    let earlier: Double
    let meal: Double
    let color: Color

    private var earlierShare: Double { min(max(earlier, 0), 1) }
    private var mealShare: Double { min(max(meal, 0), 1 - earlierShare) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                color.opacity(0.4).frame(width: proxy.size.width * earlierShare)
                color.frame(width: proxy.size.width * mealShare)
            }
        }
        .frame(height: 6)
        .background(Color(.systemFill))
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// Yesterday's version of this meal, offered as a one-tap copy.
private struct CopyMealRow: View {
    let entries: [LogEntry]
    let kcal: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copy from Yesterday")
                    .fontWeight(.medium)
                Text(entries.map(\.name).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(kcal.formatted())
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .contentShape(.rect)
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry

    private var detail: String {
        [entry.brand, entry.grams.grams, entry.estimated ? String(localized: "Estimated") : nil]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    private var segments: [MacroRingSegment] { MacroRingSegment.segments(entry.totals) }

    var body: some View {
        HStack(spacing: 12) {
            MacroRing(segments: segments, lineWidth: 4) { EmptyView() }
                .frame(width: 32, height: 32)
                .accessibilityElement()
                .accessibilityLabel(MacroRingSegment.accessibilityLabel(for: segments))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Int(entry.kcal).formatted())
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
