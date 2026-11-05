import Combine
import ConvexMobile
import Foundation
import HealthKit
import Observation

/// Sends new workouts and steps from Apple Health to the backend.
/// See docs/superpowers/specs/2026-11-05-workout-import-design.md.
@Observable
final class HealthSync {
    static let shared = HealthSync()

    private static let connectedKey = "healthConnected"
    private static let firstSyncDays = 365
    private static let recentStepDays = 7
    private static let batchSize = 100
    /// HealthKit stops waking apps that take too long to call back.
    private static let backgroundLimit = Duration.seconds(20)

    private(set) var isConnected = UserDefaults.standard.bool(forKey: HealthSync.connectedKey)
    private(set) var lastError: String?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsAnotherSync = false
    @ObservationIgnored private var isObserving = false

    private let stepCount = HKQuantityType(.stepCount)
    private let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private let basalEnergy = HKQuantityType(.basalEnergyBurned)
    private let distances = [
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming),
    ]

    /// Shows the Health permission sheet, then runs the first sync.
    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = String(localized: "Apple Health isn't available on this device.")
            return
        }
        do {
            let read = Set<HKObjectType>(distances + [.workoutType(), stepCount, activeEnergy, basalEnergy])
            try await store.requestAuthorization(toShare: [], read: read)
            isConnected = true
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
            startObserving()
            await sync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Wakes the app for new workouts. Must run at launch, because a background launch only stays
    /// alive for an observer that's already registered.
    func startObserving() {
        guard isConnected, !isObserving else { return }
        isObserving = true
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { @Sendable _, completion, error in
            Task { @MainActor in
                guard error == nil else { return completion() }
                await self.syncInBackground(completion: completion)
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate) { _, error in
            if let error { print("Health background delivery failed: \(error)") }
        }
    }

    func sync() async {
        guard isConnected else { return }
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherSync = false
            do {
                try await syncOnce()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                print("Health sync failed: \(error)")
            }
        } while needsAnotherSync
    }

    /// Calls back when the sync ends or the time limit passes, whichever comes first.
    private func syncInBackground(completion: @escaping () -> Void) async {
        var isFinished = false
        let finish = {
            guard !isFinished else { return }
            isFinished = true
            completion()
        }
        Task {
            try? await Task.sleep(for: Self.backgroundLimit)
            finish()
        }
        await sync()
        finish()
    }

    private func syncOnce() async throws {
        guard let userId = try await signedInUserId() else { return }
        // The version forces one full re-send when the uploaded data gains a field.
        let anchorKey = "healthAnchor.v2.\(userId)"
        let anchor = loadAnchor(forKey: anchorKey)
        let oldest = Calendar.current.date(byAdding: .day, value: -Self.firstSyncDays, to: .now)

        let changes = try await HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: oldest, end: nil))],
            anchor: anchor
        ).result(for: store)
        let stepDays = anchor == nil ? Self.firstSyncDays : Self.recentStepDays
        let steps = try await dailySteps(days: stepDays)

        try await upload(
            workouts: changes.addedSamples.map(fields(for:)),
            deletedIds: changes.deletedObjects.map(\.uuid.uuidString),
            steps: steps)
        // Only now: if the upload failed, the next sync sends the same changes again.
        saveAnchor(changes.newAnchor, forKey: anchorKey)
    }

    /// Waits for login, which a background launch may not have finished.
    private func signedInUserId() async throws -> String? {
        for await state in convex.authState.values {
            if case .authenticated = state { break }
        }
        for try await user in convex.subscribe(to: "auth:getCurrentUser", yielding: CurrentUser?.self).values {
            return user?.id
        }
        return nil
    }

    private func upload(
        workouts: [[String: ConvexEncodable?]], deletedIds: [String], steps: [[String: ConvexEncodable?]]
    ) async throws {
        func batch<Item>(_ items: [Item], _ index: Int) -> [Item] {
            Array(items.dropFirst(index * Self.batchSize).prefix(Self.batchSize))
        }
        let longest = max(workouts.count, deletedIds.count, steps.count)
        let batches = (longest + Self.batchSize - 1) / Self.batchSize
        for index in 0..<batches {
            try await convex.mutation("workouts:sync", with: [
                "workouts": batch(workouts, index) as [ConvexEncodable?],
                "deletedIds": batch(deletedIds, index) as [ConvexEncodable?],
                "steps": batch(steps, index) as [ConvexEncodable?],
            ])
        }
    }

    /// Absent values are left out: the client sends `nil` as null, which the backend rejects.
    private func fields(for workout: HKWorkout) -> [String: ConvexEncodable?] {
        var fields: [String: ConvexEncodable?] = [
            "externalId": workout.uuid.uuidString,
            "sourceBundleId": workout.sourceRevision.source.bundleIdentifier,
            "day": Days.key(for: workout.startDate),
            "sport": Self.sport(for: workout.workoutActivityType),
            "startAt": (workout.startDate.timeIntervalSince1970 * 1000).rounded(),
            "durationSec": workout.duration,
        ]
        func kcal(_ type: HKQuantityType) -> Double? {
            workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        }
        if let active = kcal(activeEnergy) { fields["kcal"] = active }
        if let basal = kcal(basalEnergy) { fields["basalKcal"] = basal }
        let distance = distances
            .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            .first { $0 > 0 }
        if let distance { fields["distanceM"] = distance }
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber {
            fields["indoor"] = indoor.boolValue
        }
        return fields
    }

    /// Totals across every source, plus the part from watches and trackers. A phone misses
    /// whatever happens while it's on a desk, so only the latter is used for targets.
    private func dailySteps(days: Int) async throws -> [[String: ConvexEncodable?]] {
        let all = try await stepTotals(days: days, matching: nil)
        let phone = HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: ["iPhone"])
        let wearable = try await stepTotals(days: days, matching: NSCompoundPredicate(notPredicateWithSubpredicate: phone))
        return all.map { day, steps in
            var fields: [String: ConvexEncodable?] = ["day": day, "steps": steps]
            if let wearableSteps = wearable[day] { fields["wearableSteps"] = wearableSteps }
            return fields
        }
    }

    /// Whole-number steps per day key.
    private func stepTotals(days: Int, matching predicate: NSPredicate?) async throws -> [String: Double] {
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: 1 - days, to: today)
        let dates = HKQuery.predicateForSamples(withStart: start, end: nil)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: stepCount,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [dates] + (predicate.map { [$0] } ?? []))),
            options: .cumulativeSum,
            anchorDate: today,
            intervalComponents: DateComponents(day: 1))
        do {
            var totals: [String: Double] = [:]
            for statistics in try await query.result(for: store).statistics() {
                if let steps = statistics.sumQuantity()?.doubleValue(for: .count()) {
                    totals[Days.key(for: statistics.startDate)] = steps.rounded()
                }
            }
            return totals
        } catch let error as HKError where error.code == .errorNoData {
            return [:]
        }
    }

    private func loadAnchor(forKey key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, forKey key: String) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Values mirror `sportValidator` in convex/schema.ts.
    private static func sport(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "run"
        case .cycling: "ride"
        case .swimming: "swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        case .hiking: "hike"
        case .walking: "walk"
        case .flexibility, .yoga, .pilates: "mobility"
        default: "other"
        }
    }
}
