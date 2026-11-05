import Combine
import ConvexMobile
import SwiftUI

/// Find a food to add to a meal: recents before typing, search after.
struct AddFoodSheet: View {
    let day: Date
    let meal: MealKind

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recents: [RecentFood] = []
    /// `nil` until the current query has results.
    @State private var results: [FoodResult]?
    @State private var errorMessage: String?

    private struct Selection: Hashable {
        let food: FoodResult
        let grams: Double
    }

    private static let searchDelay: Duration = .milliseconds(250)
    private static let defaultGrams: Double = 100

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    recentsSection
                } else {
                    resultsSection
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search foods")
            .navigationTitle(meal.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(for: Selection.self) { selection in
                AmountView(food: selection.food, initialGrams: selection.grams, primaryTitle: "Add") { grams in
                    try await add(selection.food, grams: grams, origin: "search")
                    dismiss()
                }
            }
        }
        .task { await watchRecents() }
        .task(id: trimmedQuery) { await watchSearch(for: trimmedQuery) }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents) { recent in
                    NavigationLink(value: Selection(food: recent.food, grams: recent.lastGrams)) {
                        FoodRow(food: recent.food)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let results {
            if results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
            ForEach(results) { food in
                NavigationLink(value: Selection(food: food, grams: defaultGrams(for: food))) {
                    FoodRow(food: food)
                }
            }
        }
    }

    /// The last amount logged, then one serving, then 100 g.
    private func defaultGrams(for food: FoodResult) -> Double {
        recents.first { $0.foodId == food.id }?.lastGrams ?? food.servingG ?? Self.defaultGrams
    }

    private func add(_ food: FoodResult, grams: Double, origin: String) async throws {
        try await convex.mutation("logs:add", with: [
            "day": Days.key(for: day),
            "meal": meal.rawValue,
            "foodId": food.id,
            "grams": grams,
            "origin": origin,
        ])
    }

    private func watchRecents() async {
        do {
            let updates = convex.subscribe(to: "logs:recents", yielding: [RecentFood].self)
            for try await value in updates.values { recents = value }
        } catch {
            print("logs:recents failed: \(error)")
        }
    }

    /// Cancelled whenever the query changes, which also drops a pending search.
    private func watchSearch(for query: String) async {
        results = nil
        errorMessage = nil
        guard !query.isEmpty else { return }
        do {
            try await Task.sleep(for: Self.searchDelay)
            let updates = convex.subscribe(
                to: "foods:search", with: ["query": query], yielding: [FoodResult].self)
            for try await value in updates.values { results = value }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.convexMessage
        }
    }
}

struct FoodRow: View {
    let food: FoodResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(food.name)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let energy = String(localized: "\(Int(food.per100g.kcal).kcal) per 100 g")
        return [food.brand, energy].compactMap(\.self).joined(separator: " · ")
    }
}
