import Foundation
import Testing

@testable import fuelx

/// Hands out streams the test can push values through, and counts subscriptions.
private final class FakeDayData: DayDataSource {
    var targetsStarted = 0
    var targets: AsyncThrowingStream<TargetsAnswer?, Error>.Continuation?
    var lastInProgress: Bool?
    var entries: AsyncThrowingStream<DayEntries?, Error>.Continuation?
    var workouts: AsyncThrowingStream<WorkoutDay?, Error>.Continuation?
    var progress: AsyncThrowingStream<[DayProgress]?, Error>.Continuation?

    func targets(for day: Date, inProgress: Bool) -> AsyncThrowingStream<TargetsAnswer?, Error> {
        targetsStarted += 1
        lastInProgress = inProgress
        let (stream, continuation) = AsyncThrowingStream<TargetsAnswer?, Error>.makeStream()
        targets = continuation
        return stream
    }

    func entries(for day: Date) -> AsyncThrowingStream<DayEntries?, Error> {
        let (stream, continuation) = AsyncThrowingStream<DayEntries?, Error>.makeStream()
        entries = continuation
        return stream
    }

    func workouts(for day: Date) -> AsyncThrowingStream<WorkoutDay?, Error> {
        let (stream, continuation) = AsyncThrowingStream<WorkoutDay?, Error>.makeStream()
        workouts = continuation
        return stream
    }

    func progress(for days: [Date], today: Date) -> AsyncThrowingStream<[DayProgress]?, Error> {
        let (stream, continuation) = AsyncThrowingStream<[DayProgress]?, Error>.makeStream()
        progress = continuation
        return stream
    }
}

private func sampleTargets(calories: Double = 2127) -> TargetsAnswer {
    .targets(NutritionTargets(
        calories: calories, maintenanceCalories: 2402, stepsUsed: nil, goalAdjustment: -275,
        workoutCalories: 0, proteinG: 149, carbsG: 250, fatG: 59, carbsGPerKg: 2.7,
        goalRateCapped: false, calorieFloorApplied: false, lowCarbs: true))
}

private func sampleEntries(kcal: Double) -> DayEntries {
    let total = NutritionTotals(kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0)
    let meals = MealTotals(breakfast: total, lunch: total, dinner: total, snack: total)
    return DayEntries(entries: [], totals: total, mealTotals: meals)
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "day-store-\(UUID().uuidString).json")
}

private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

/// Lets anything already delivered reach the store.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

@Suite struct DayStoreTests {
    private let day = Days.today
    private let source = FakeDayData()

    private func makeStore(
        fileURL: URL = tempFile(),
        stopDelay: Duration = .seconds(60),
        isToday: @escaping (Date) -> Bool = { _ in true }
    ) -> DayStore {
        DayStore(
            source: source, fileURL: fileURL, saveDelay: .zero, stopDelay: stopDelay,
            retryDelay: .milliseconds(1), isToday: isToday)
    }

    @Test func saysLoadingBeforeAnyAnswer() {
        let store = makeStore()
        guard case .loading = store.targets(for: day) else {
            Issue.record("Expected loading")
            return
        }
        #expect(store[day].entries == nil)
    }

    @Test func waitsForASessionBeforeSubscribing() async {
        let store = makeStore()
        let view = Task { await store.watch(.day(day)) }
        await settle()
        #expect(source.targetsStarted == 0)

        store.sessionDidChange(UUID())
        await eventually { source.targetsStarted == 1 }
        view.cancel()
    }

    @Test func liveValuesReachTheDay() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }

        source.targets?.yield(sampleTargets())
        source.entries?.yield(sampleEntries(kcal: 1114))
        await eventually { store[day].entries?.totals.kcal == 1114 }
        #expect(store.targets(for: day).loaded?.calories == 2127)
        view.cancel()
    }

    @Test func survivesARestart() async {
        let file = tempFile()
        let store = makeStore(fileURL: file)
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        await store.flush()
        view.cancel()

        let restarted = makeStore(fileURL: file)
        #expect(restarted.targets(for: day).loaded?.calories == 2127)
    }

    @Test func ignoresAnUnreadableFile() throws {
        let file = tempFile()
        try Data("not json".utf8).write(to: file)
        #expect(makeStore(fileURL: file).isEmpty)
    }

    @Test func missingEntriesAndWorkoutsKeepWhatIsKnown() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.entries != nil }

        source.entries?.yield(sampleEntries(kcal: 1114))
        await eventually { store[day].entries != nil }
        source.entries?.yield(nil)
        source.workouts?.yield(nil)
        await settle()
        #expect(store[day].entries?.totals.kcal == 1114)
        view.cancel()
    }

    @Test func signedOutKeepsCachedTargets() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }

        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        source.targets?.yield(nil)
        await settle()
        #expect(store.targets(for: day).loaded?.calories == 2127)
        view.cancel()
    }

    @Test func aFailedSubscriptionComesBack() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }

        source.targets?.finish(throwing: CancellationError())
        await eventually { source.targetsStarted == 2 }
        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        view.cancel()
    }

    @Test func theDayStopsBeingInProgressAfterMidnight() async {
        var isToday = true
        let store = makeStore(isToday: { _ in isToday })
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        #expect(source.lastInProgress == true)

        store.todayDidChange()
        await settle()
        #expect(source.targetsStarted == 1)

        isToday = false
        store.todayDidChange()
        await eventually { source.targetsStarted == 2 }
        #expect(source.lastInProgress == false)
        view.cancel()
    }

    @Test func noProfileReplacesCachedTargets() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }

        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        source.targets?.yield(.noProfile)
        await eventually { store[day].targets == nil }
        guard case .noProfile = store.targets(for: day) else {
            Issue.record("Expected no profile")
            return
        }
        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        view.cancel()
    }

    @Test func noProfileForgetsProgress() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let week = Task { await store.watch(.progress(days: [day], today: day)) }
        let page = Task { await store.watch(.day(day)) }
        await eventually { source.progress != nil && source.targets != nil }

        source.progress?.yield([DayProgress(day: Days.key(for: day), kcal: 100, targetKcal: 2000)])
        await eventually { store[day].progress != nil }
        source.targets?.yield(.noProfile)
        await eventually { store[day].progress == nil }
        week.cancel()
        page.cancel()
    }

    @Test func viewsOfADayShareASubscription() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let page = Task { await store.watch(.day(day)) }
        let meal = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        await settle()
        #expect(source.targetsStarted == 1)
        page.cancel()
        meal.cancel()
    }

    @Test func returningWithinTheDelayKeepsTheSubscription() async {
        let store = makeStore(stopDelay: .seconds(60))
        store.sessionDidChange(UUID())
        let first = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        first.cancel()
        await settle()

        let second = Task { await store.watch(.day(day)) }
        await settle()
        #expect(source.targetsStarted == 1)
        second.cancel()
    }

    @Test func stopsAfterTheLastViewLeaves() async {
        let store = makeStore(stopDelay: .milliseconds(10))
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        view.cancel()

        await eventually {
            if case .terminated = source.targets?.yield(nil) { true } else { false }
        }
        let back = Task { await store.watch(.day(day)) }
        await eventually { source.targetsStarted == 2 }
        back.cancel()
    }

    @Test func aNewSessionResubscribes() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targetsStarted == 1 }

        store.sessionDidChange(nil)
        store.sessionDidChange(UUID())
        await eventually { source.targetsStarted == 2 }
        view.cancel()
    }

    @Test func dropsAnswersFromThePreviousSession() async {
        let store = makeStore()
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }

        let previous = source.targets
        store.sessionDidChange(nil)
        previous?.yield(sampleTargets())
        await settle()
        #expect(store[day].targets == nil)
        view.cancel()
    }

    @Test func clearForgetsEverythingForGood() async {
        let file = tempFile()
        let store = makeStore(fileURL: file)
        store.sessionDidChange(UUID())
        let view = Task { await store.watch(.day(day)) }
        await eventually { source.targets != nil }
        source.targets?.yield(sampleTargets())
        await eventually { store.targets(for: day).loaded != nil }
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: file.path()))

        // A value right before clearing leaves a save pending, which must not bring it back.
        source.targets?.yield(sampleTargets(calories: 3000))
        await eventually { store.targets(for: day).loaded?.calories == 3000 }
        store.clear()
        await settle()
        await store.flush()
        #expect(store.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path()))
    }

    @Test func savesRecentDaysButKeepsOlderOnesInMemory() async {
        let file = tempFile()
        let store = makeStore(fileURL: file)
        store.sessionDidChange(UUID())
        let week = (0..<20).compactMap { Days.calendar.date(byAdding: .day, value: -$0, to: day) }
        let view = Task { await store.watch(.progress(days: week, today: day)) }
        await eventually { source.progress != nil }

        source.progress?.yield(
            week.map { DayProgress(day: Days.key(for: $0), kcal: 100, targetKcal: 2000) })
        await eventually { store[week[19]].progress != nil }
        await store.flush()
        view.cancel()

        let restarted = makeStore(fileURL: file)
        #expect(restarted[day].progress != nil)
        #expect(restarted[week[13]].progress != nil)
        #expect(restarted[week[14]].progress == nil)
    }
}
