import Foundation

/// One calendar day's calorie balance.
struct DayLog {
    let day: Date
    let mealCalories: Int
    let workouts: [Workout]

    var fuelCalories: Int { workouts.reduce(0) { $0 + $1.fuelCalories } }
    /// Meals plus fuel taken during workouts.
    var caloriesIn: Int { mealCalories + fuelCalories }
    var caloriesBurned: Int { workouts.reduce(0) { $0 + $1.caloriesBurned } }
    var netCalories: Int { caloriesIn - caloriesBurned }
}

struct Workout: Identifiable {
    enum Sport: String {
        case run = "Run"
        case ride = "Ride"
        case swim = "Swim"
        case strength = "Strength"

        var systemImage: String {
            switch self {
            case .run: "figure.run"
            case .ride: "figure.outdoor.cycle"
            case .swim: "figure.pool.swim"
            case .strength: "figure.strengthtraining.traditional"
            }
        }
    }

    let id: String
    let sport: Sport
    let title: String
    let start: Date
    let duration: Duration
    let caloriesBurned: Int
    /// Fuel taken during this workout.
    let fuel: [FuelItem]

    var fuelCalories: Int { fuel.reduce(0) { $0 + $1.calories } }
}

struct FuelItem: Identifiable {
    let id: String
    let name: String
    let calories: Int
    let time: Date
}
