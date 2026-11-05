import Combine
import ConvexMobile
import Foundation

/// Where ``DayStore`` gets live data. A `nil` means signed out, or no profile for targets.
protocol DayDataSource {
    func targets(for day: Date) -> AsyncThrowingStream<NutritionTargets?, Error>
    func entries(for day: Date) -> AsyncThrowingStream<DayEntries?, Error>
    func workouts(for day: Date) -> AsyncThrowingStream<WorkoutDay?, Error>
    func progress(for days: [Date], today: Date) -> AsyncThrowingStream<[DayProgress]?, Error>
}

struct ConvexDayData: DayDataSource {
    func targets(for day: Date) -> AsyncThrowingStream<NutritionTargets?, Error> {
        stream("nutrition:targetsForDay", NutritionTargets.queryArgs(for: day))
    }

    func entries(for day: Date) -> AsyncThrowingStream<DayEntries?, Error> {
        stream("logs:forDay", ["day": Days.key(for: day)])
    }

    func workouts(for day: Date) -> AsyncThrowingStream<WorkoutDay?, Error> {
        stream("workouts:forDay", ["day": Days.key(for: day)])
    }

    func progress(for days: [Date], today: Date) -> AsyncThrowingStream<[DayProgress]?, Error> {
        let keys: [ConvexEncodable?] = days.map(Days.key(for:))
        return stream("nutrition:progressForDays", ["days": keys, "today": Days.key(for: today)])
    }

    private func stream<Value: Decodable>(
        _ query: String, _ args: [String: ConvexEncodable?]
    ) -> AsyncThrowingStream<Value, Error> {
        let updates = convex.subscribe(to: query, with: args, yielding: Value.self)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in updates.values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
