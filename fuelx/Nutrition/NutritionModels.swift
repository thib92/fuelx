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

/// Mirrors `activityLevelValidator` in convex/schema.ts. Everyday activity only, used when a
/// day has no steps from a watch. Workouts are added to targets separately.
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

/// Returned by `nutrition:targetsForDay`, which is only `null` when signed out.
nonisolated enum TargetsAnswer: Decodable, Sendable {
    case noProfile
    case targets(NutritionTargets)

    private enum CodingKeys: String, CodingKey {
        case noProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = container.contains(.noProfile)
            ? .noProfile : .targets(try NutritionTargets(from: decoder))
    }
}

/// Numbers are Convex float64s, hence `Double`.
nonisolated struct NutritionTargets: Codable, Sendable {
    let calories: Double
    let maintenanceCalories: Double
    let stepsUsed: Double?
    let goalAdjustment: Double
    /// Included in `calories`.
    let workoutCalories: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let carbsGPerKg: Double
    let goalRateCapped: Bool
    let calorieFloorApplied: Bool
    let lowCarbs: Bool

    /// Sized like a typical day, for a redacted overview while the first result loads.
    static let placeholder = NutritionTargets(
        calories: 2000, maintenanceCalories: 2000, stepsUsed: nil, goalAdjustment: 0,
        workoutCalories: 0, proteinG: 150, carbsG: 250, fatG: 60, carbsGPerKg: 3,
        goalRateCapped: false, calorieFloorApplied: false, lowCarbs: false)
}

/// Returned by `nutrition:progressForDays`.
nonisolated struct DayProgress: Codable, Sendable {
    let day: String
    let kcal: Double
    let targetKcal: Double

    var fraction: Double { targetKcal > 0 ? kcal / targetKcal : 0 }
}

/// An error people can run into, sent by `userError` in convex/lib/userError.ts.
nonisolated struct UserError: Decodable, Sendable {
    let code: String
    /// The backend's English, for a code this version of the app doesn't know.
    let message: String
    var min: Double?
    var max: Double?

    var localizedMessage: String {
        let min = (min ?? 0).formatted()
        let max = (max ?? 0).formatted()
        return switch code {
        case "notSignedIn": String(localized: "You need to be signed in.")
        case "nameRequired": String(localized: "Enter a name.")
        case "nameTooLong": String(localized: "Names can be up to \(max) characters.")
        case "invalidNutrition": String(localized: "Those values don't add up.")
        case "invalidServing": String(localized: "Serving size must be between 0 and \(max) g.")
        case "invalidGrams": String(localized: "Grams must be between 0 and \(max).")
        case "entryNotFound": String(localized: "Entry not found.")
        case "foodNotFound": String(localized: "Food not found.")
        case "foodNotSaved": String(localized: "That food couldn't be saved.")
        case "invalidHeight": String(localized: "Height must be between \(min) and \(max) cm.")
        case "invalidWeight": String(localized: "Weight must be between \(min) and \(max) kg.")
        default: message
        }
    }
}

extension Error {
    /// The message from a Convex `ConvexError`, or the usual description.
    nonisolated var convexMessage: String {
        guard case ClientError.ConvexError(let data)? = self as? ClientError else {
            return localizedDescription
        }
        let json = Data(data.utf8)
        if let error = try? JSONDecoder().decode(UserError.self, from: json) {
            return error.localizedMessage
        }
        return (try? JSONDecoder().decode(String.self, from: json)) ?? localizedDescription
    }
}
