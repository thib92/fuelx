import Foundation

/// Mirrors `mealValidator` in convex/schema.ts.
nonisolated enum MealKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack
    var id: Self { self }

    var label: String {
        switch self {
        case .breakfast: String(localized: "Breakfast")
        case .lunch: String(localized: "Lunch")
        case .dinner: String(localized: "Dinner")
        case .snack: String(localized: "Snack")
        }
    }

    var systemImage: String {
        switch self {
        case .breakfast: "sun.horizon"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        }
    }
}

nonisolated struct Per100g: Decodable, Hashable, Sendable {
    let kcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

/// Returned by `foods:search`.
nonisolated struct FoodResult: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let brand: String?
    let per100g: Per100g
    let servingG: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, brand, per100g, servingG
    }
}

/// Returned by `logs:recents`.
nonisolated struct RecentFood: Decodable, Identifiable, Sendable {
    let foodId: String
    let name: String
    let brand: String?
    let per100g: Per100g
    let servingG: Double?
    let lastGrams: Double

    var id: String { foodId }

    var food: FoodResult {
        FoodResult(id: foodId, name: name, brand: brand, per100g: per100g, servingG: servingG)
    }
}

/// Rounded by the backend: whole kcal, macros to 1 decimal.
nonisolated struct NutritionTotals: Decodable, Sendable {
    let kcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

nonisolated struct LogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let meal: MealKind
    let name: String
    let brand: String?
    let grams: Double
    let kcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let estimated: Bool
    let foodId: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case meal, name, brand, grams, kcal, proteinG, carbsG, fatG, estimated, foodId
    }
}

/// Returned by `logs:forDay`.
nonisolated struct DayEntries: Decodable, Sendable {
    let entries: [LogEntry]
    let totals: NutritionTotals
    let mealTotals: MealTotals

    func entries(for meal: MealKind) -> [LogEntry] {
        entries.filter { $0.meal == meal }
    }
}

nonisolated struct MealTotals: Decodable, Sendable {
    let breakfast: NutritionTotals
    let lunch: NutritionTotals
    let dinner: NutritionTotals
    let snack: NutritionTotals

    subscript(meal: MealKind) -> NutritionTotals {
        switch meal {
        case .breakfast: breakfast
        case .lunch: lunch
        case .dinner: dinner
        case .snack: snack
        }
    }
}
