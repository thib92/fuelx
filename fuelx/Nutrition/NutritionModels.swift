import ConvexMobile
import Foundation

nonisolated enum Sex: String, Codable, CaseIterable, Identifiable, Sendable {
    case male, female
    var id: Self { self }

    var label: String {
        switch self {
        case .male: String(localized: "Male")
        case .female: String(localized: "Female")
        }
    }
}

/// Mirrors `activityLevelValidator` in convex/schema.ts. Everyday activity only: workouts
/// don't count toward targets yet, and will be added on top once they're connected.
nonisolated enum ActivityLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case sedentary, light, moderate
    var id: Self { self }

    var label: String {
        switch self {
        case .sedentary: String(localized: "Sedentary")
        case .light: String(localized: "Lightly active")
        case .moderate: String(localized: "Active")
        }
    }

    var detail: String {
        switch self {
        case .sedentary: String(localized: "Mostly sitting, like a desk job")
        case .light: String(localized: "On your feet part of the day, like teaching or retail")
        case .moderate: String(localized: "On your feet or doing physical work most of the day")
        }
    }
}

nonisolated enum WeightGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case lose, maintain, gain
    var id: Self { self }

    var label: String {
        switch self {
        case .lose: String(localized: "Lose")
        case .maintain: String(localized: "Maintain")
        case .gain: String(localized: "Gain")
        }
    }

    /// Mirrors `GOAL_RATES` in convex/lib/nutritionTargets.ts, in kg/week.
    var rates: [Double] {
        switch self {
        case .lose: [0.25, 0.5]
        case .maintain: [0]
        case .gain: [0.25]
        }
    }
}

/// Returned by `profile:get`.
nonisolated struct NutritionProfile: Decodable, Sendable {
    let sex: Sex
    /// "YYYY-MM-DD"
    let birthDate: String
    let heightCm: Double
    let weightKg: Double
    let activityLevel: ActivityLevel
    let goal: WeightGoal
    let goalRateKgPerWeek: Double
    let proteinGPerKg: Double
    let fatPercent: Double
}

/// Returned by `nutrition:targetsForDay`. Numbers are Convex float64s, hence `Double`.
nonisolated struct NutritionTargets: Decodable, Sendable {
    let calories: Double
    let maintenanceCalories: Double
    let goalAdjustment: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let carbsGPerKg: Double
    let goalRateCapped: Bool
    let calorieFloorApplied: Bool
    let lowCarbs: Bool
}

extension Error {
    /// The message from a Convex `ConvexError`, or the usual description.
    nonisolated var convexMessage: String {
        if case ClientError.ConvexError(let data)? = self as? ClientError,
            let message = try? JSONDecoder().decode(String.self, from: Data(data.utf8))
        {
            return message
        }
        return localizedDescription
    }
}
