import Foundation

/// Stand-in for the data layer: generates a plausible, stable log for any day.
///
/// The same day always produces the same log, and today's log only contains what has already
/// happened. Replace with a Convex query (e.g. `logs:forDay`) once the backend exists.
enum MockDayLogs {
    static func log(for day: Date, now: Date = .now) -> DayLog {
        let calendar = Calendar.current
        let index = calendar.dateComponents([.day], from: Date(timeIntervalSinceReferenceDate: 0), to: day).day ?? 0
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(index)))

        // Some days were never tracked.
        if index % 9 == 4 { return DayLog(day: day, meals: [], workouts: []) }

        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func kcal(_ range: ClosedRange<Int>) -> Int {
            Int.random(in: range, using: &rng) * 10
        }

        var meals = [
            Meal(id: "\(index)-breakfast", kind: .breakfast,
                 name: ["Oatmeal & berries", "Eggs on toast", "Yogurt & granola"].randomElement(using: &rng)!,
                 calories: kcal(45...75), time: at(7, 30)),
            Meal(id: "\(index)-lunch", kind: .lunch,
                 name: ["Chicken rice bowl", "Pasta salad", "Turkey sandwich"].randomElement(using: &rng)!,
                 calories: kcal(60...90), time: at(12, 30)),
            Meal(id: "\(index)-dinner", kind: .dinner,
                 name: ["Salmon & potatoes", "Beef stir-fry", "Lentil curry"].randomElement(using: &rng)!,
                 calories: kcal(70...110), time: at(19, 30)),
        ]
        if Bool.random(using: &rng) {
            meals.insert(
                Meal(id: "\(index)-snack", kind: .snack,
                     name: ["Banana & peanut butter", "Recovery shake", "Rice cakes"].randomElement(using: &rng)!,
                     calories: kcal(20...40), time: at(16, 0)),
                at: 2)
        }

        var workouts: [Workout] = []
        if index % 3 != 0 {
            let isLongDay = index % 7 == 6
            let sport: Workout.Sport = isLongDay ? .ride : [.run, .ride, .swim, .strength].randomElement(using: &rng)!
            let minutes = isLongDay ? Int.random(in: 150...240, using: &rng) : Int.random(in: 40...100, using: &rng)
            let kcalPerMinute = switch sport {
            case .run: 12
            case .ride: 10
            case .swim: 9
            case .strength: 6
            }
            let start = isLongDay ? at(8, 0) : (Bool.random(using: &rng) ? at(6, 30) : at(18, 0))
            let title = switch sport {
            case .run: isLongDay ? "Long run" : ["Easy run", "Tempo run", "Intervals"].randomElement(using: &rng)!
            case .ride: isLongDay ? "Long ride" : ["Endurance ride", "Sweet spot", "Recovery spin"].randomElement(using: &rng)!
            case .swim: ["Technique swim", "Threshold sets"].randomElement(using: &rng)!
            case .strength: "Gym session"
            }

            // Endurance sessions over ~75 min get fuel roughly every 40 min.
            let fuelOptions = [("Energy gel", 100), ("Drink mix, 500 ml", 200), ("Energy bar", 230), ("Chews", 160)]
            let fuel: [FuelItem] = sport == .strength || minutes < 75 ? [] : (1...(minutes / 40)).map { n in
                let (name, calories) = fuelOptions.randomElement(using: &rng)!
                return FuelItem(id: "\(index)-fuel-\(n)", name: name, calories: calories,
                                time: start.addingTimeInterval(Double(n * 40 * 60)))
            }

            workouts.append(Workout(
                id: "\(index)-workout", sport: sport, title: title, start: start,
                duration: .seconds(minutes * 60),
                caloriesBurned: (minutes * kcalPerMinute / 10 + Int.random(in: -5...5, using: &rng)) * 10,
                fuel: fuel))
        }

        // Today: only what has happened so far.
        return DayLog(
            day: day,
            meals: meals.filter { $0.time <= now },
            workouts: workouts.filter { $0.start.addingTimeInterval(TimeInterval($0.duration.components.seconds)) <= now })
    }
}

/// Small seeded RNG so mock days are stable across launches.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
