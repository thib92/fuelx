import Foundation

/// Returned by `workouts:forDay`.
nonisolated struct WorkoutDay: Codable, Sendable {
    let workouts: [Workout]
    let steps: Double?
}

nonisolated struct Workout: Codable, Identifiable, Sendable {
    /// Mirrors `sportValidator` in convex/schema.ts.
    nonisolated enum Sport: String, Codable, Sendable {
        case run, ride, swim, strength, hike, walk, mobility, other

        var label: String {
            switch self {
            case .run: String(localized: "Run")
            case .ride: String(localized: "Ride")
            case .swim: String(localized: "Swim")
            case .strength: String(localized: "Strength")
            case .hike: String(localized: "Hike")
            case .walk: String(localized: "Walk")
            case .mobility: String(localized: "Mobility")
            case .other: String(localized: "Other")
            }
        }

        var systemImage: String {
            switch self {
            case .run: "figure.run"
            case .ride: "figure.outdoor.cycle"
            case .swim: "figure.pool.swim"
            case .strength: "figure.strengthtraining.traditional"
            case .hike: "figure.hiking"
            case .walk: "figure.walk"
            case .mobility: "figure.flexibility"
            case .other: "figure.mixed.cardio"
            }
        }
    }

    let id: String
    let sport: Sport
    let durationSec: Double
    let activeKcal: Double
    let distanceM: Double?
    let indoor: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case sport, durationSec, activeKcal, distanceM, indoor
    }

    var caloriesBurned: Int { Int(activeKcal) }

    /// Health has no activity names, so the title comes from the sport.
    var title: String {
        sport == .ride && indoor == true ? String(localized: "Indoor Ride") : sport.label
    }

    /// "35.4 km · 1 hr, 10 min"
    var detail: String {
        let duration = Duration.seconds(durationSec)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        guard let distanceM, distanceM > 0 else { return duration }
        let distance = Measurement(value: distanceM / 1000, unit: UnitLength.kilometers).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        return "\(distance) · \(duration)"
    }
}
