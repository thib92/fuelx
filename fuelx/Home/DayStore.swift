import Foundation
import Observation
import SwiftUI

/// What the app knows about a day, whether it came from disk or from Convex.
nonisolated struct DaySnapshot: Codable, Sendable {
    var targets: NutritionTargets?
    var entries: DayEntries?
    var workouts: WorkoutDay?
    var progress: DayProgress?

    var isEmpty: Bool {
        targets == nil && entries == nil && workouts == nil && progress == nil
    }
}

/// A day's targets, with "no answer yet" and "no profile" told apart.
enum DayTargets {
    case loading
    case noProfile
    case loaded(NutritionTargets)

    var loaded: NutritionTargets? {
        if case .loaded(let targets) = self { targets } else { nil }
    }
}

/// One object per day, so a change to one day only redraws the views showing that day.
@Observable
private final class DayRecord {
    var snapshot: DaySnapshot
    var hasNoProfile = false

    init(snapshot: DaySnapshot = DaySnapshot()) {
        self.snapshot = snapshot
    }
}

/// Day data, cached and live. Views read a day with `store[day]`, keep it fresh with
/// `store.watch(_:)`, and never need to know where the numbers came from.
///
/// Reads are synchronous, so pages have real numbers in their first frame. The recent days are
/// saved to Caches, which isn't backed up and which the system may empty: all of it can be fetched
/// again. Convex keeps nothing on disk itself.
///
/// The data belongs to the current session, so ``AuthModel`` reports session changes here and
/// clears the store when the account changes.
final class DayStore {
    /// Something to keep fresh. Views for the same one share a subscription.
    nonisolated enum Watch: Hashable, Sendable {
        case day(Date)
        /// Progress for these days. `today` is the day in progress.
        case progress(days: [Date], today: Date)
    }

    /// A running subscription, kept for a moment after its last view leaves.
    private struct Subscription {
        var watchers = 0
        var tasks: [Task<Void, Never>] = []
        var pendingStop: Task<Void, Never>?
        /// Whether a `.day` subscription was started as the day in progress.
        var inProgress = false
    }

    static let shared = DayStore(source: ConvexDayData(), fileURL: DayStore.defaultFileURL)

    /// Bump the name when a cached model changes, though a file that no longer decodes is ignored.
    private nonisolated static let defaultFileURL = URL.cachesDirectory
        .appending(path: "day-cache-v1.json")
    /// Covers this week and last week's strip.
    private static let maxSavedDays = 14
    private static let maxRetryDelay: Duration = .seconds(30)

    /// Reading a day creates its record even if nothing is known yet, so that views showing it
    /// hear about the first answer. Records are never removed, because views are observing them.
    private var records: [String: DayRecord]

    private let source: DayDataSource
    private let fileURL: URL
    private let saveDelay: Duration
    private let stopDelay: Duration
    private let retryDelay: Duration
    private let isToday: (Date) -> Bool
    private var session: UUID?
    private var subscriptions: [Watch: Subscription] = [:]
    private var pendingSave: Task<Void, Never>?
    /// Keeps file operations in order, so a save can't bring data back after `clear()`.
    private let fileQueue = DispatchQueue(label: "dev.thenry.fuelx.day-store", qos: .utility)

    /// - Parameters:
    ///   - stopDelay: Swiping recreates pages constantly, so a day stays subscribed this long
    ///     after its last view leaves.
    ///   - retryDelay: How long a failed subscription first waits before starting again.
    init(
        source: DayDataSource,
        fileURL: URL,
        saveDelay: Duration = .milliseconds(300),
        stopDelay: Duration = .seconds(10),
        retryDelay: Duration = .seconds(1),
        isToday: @escaping (Date) -> Bool = { Days.calendar.isDateInToday($0) }
    ) {
        self.source = source
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.stopDelay = stopDelay
        self.retryDelay = retryDelay
        self.isToday = isToday
        let data = try? Data(contentsOf: fileURL)
        let saved = data.flatMap { try? JSONDecoder().decode([String: DaySnapshot].self, from: $0) }
        records = (saved ?? [:]).mapValues { DayRecord(snapshot: $0) }
    }

    subscript(day: Date) -> DaySnapshot {
        record(for: Days.key(for: day)).snapshot
    }

    func targets(for day: Date) -> DayTargets {
        let record = record(for: Days.key(for: day))
        if record.hasNoProfile { return .noProfile }
        return record.snapshot.targets.map(DayTargets.loaded) ?? .loading
    }

    /// Whether no day has any data.
    var isEmpty: Bool {
        records.values.allSatisfy { $0.snapshot.isEmpty }
    }

    /// Keeps `watch` fresh until the calling task is cancelled, as `.task` does when its view
    /// leaves. Waits for a session: until then Convex answers as if signed out.
    func watch(_ watch: Watch) async {
        retain(watch)
        defer { release(watch) }
        // Never yields, so this suspends until cancelled.
        let (cancelled, continuation) = AsyncStream<Never>.makeStream()
        defer { continuation.finish() }
        for await _ in cancelled {}
    }

    /// Restarts subscriptions, so they answer for the new session.
    func sessionDidChange(_ session: UUID?) {
        self.session = session
        for watch in subscriptions.keys {
            restart(watch)
        }
    }

    /// Restarts the days that stopped or started being in progress, whose targets follow different
    /// rules. Call when the date changes.
    func todayDidChange() {
        for (watch, subscription) in subscriptions {
            if case .day(let day) = watch, subscription.inProgress != isToday(day) {
                restart(watch)
            }
        }
    }

    /// Forgets everything, for when the account changes.
    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        for record in records.values {
            record.snapshot = DaySnapshot()
            record.hasNoProfile = false
        }
        let fileURL = fileURL
        fileQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Finishes any pending save.
    func flush() async {
        await pendingSave?.value
        await withCheckedContinuation { continuation in
            fileQueue.async { continuation.resume() }
        }
    }

    private func record(for key: String) -> DayRecord {
        if let record = records[key] { return record }
        let record = DayRecord()
        records[key] = record
        return record
    }

    private func retain(_ watch: Watch) {
        subscriptions[watch, default: Subscription()].watchers += 1
        subscriptions[watch]?.pendingStop?.cancel()
        subscriptions[watch]?.pendingStop = nil
        if subscriptions[watch]?.tasks.isEmpty == true { start(watch) }
    }

    private func release(_ watch: Watch) {
        guard var subscription = subscriptions[watch] else { return }
        subscription.watchers -= 1
        if subscription.watchers == 0 {
            subscription.pendingStop = Task { [weak self, stopDelay] in
                try? await Task.sleep(for: stopDelay)
                guard !Task.isCancelled else { return }
                self?.stop(watch)
            }
        }
        subscriptions[watch] = subscription
    }

    private func stop(_ watch: Watch) {
        subscriptions[watch]?.tasks.forEach { $0.cancel() }
        subscriptions[watch] = nil
    }

    private func restart(_ watch: Watch) {
        guard let subscription = subscriptions[watch] else { return }
        subscription.tasks.forEach { $0.cancel() }
        subscription.pendingStop?.cancel()
        if subscription.watchers == 0 {
            subscriptions[watch] = nil
        } else {
            subscriptions[watch]?.pendingStop = nil
            subscriptions[watch]?.tasks = []
            start(watch)
        }
    }

    private func start(_ watch: Watch) {
        guard session != nil else { return }
        switch watch {
        case .day(let day):
            let key = Days.key(for: day)
            let inProgress = isToday(day)
            subscriptions[watch]?.inProgress = inProgress
            subscriptions[watch]?.tasks = [
                listen(to: { [source] in source.targets(for: day, inProgress: inProgress) }) {
                    [weak self] in self?.apply($0, to: key)
                },
                // These are only `nil` when signed out, which says nothing about the day.
                listen(to: { [source] in source.entries(for: day) }) { [weak self] value in
                    guard let value else { return }
                    self?.update(key) { $0.entries = value }
                },
                listen(to: { [source] in source.workouts(for: day) }) { [weak self] value in
                    guard let value else { return }
                    self?.update(key) { $0.workouts = value }
                },
            ]
        case .progress(let days, let today):
            subscriptions[watch]?.tasks = [
                listen(to: { [source] in source.progress(for: days, today: today) }) {
                    [weak self] value in
                    for item in value ?? [] {
                        self?.update(item.day) { $0.progress = item }
                    }
                }
            ]
        }
    }

    /// Delivers updates until cancelled. A failed query stays failed, so this subscribes again,
    /// backing off for as long as there are no answers. Drops anything that arrives after
    /// cancellation, which may belong to the previous session.
    private func listen<Value>(
        to updates: @escaping () -> AsyncThrowingStream<Value, Error>,
        apply: @escaping (Value) -> Void
    ) -> Task<Void, Never> {
        Task { [retryDelay] in
            var delay = retryDelay
            while !Task.isCancelled {
                do {
                    for try await value in updates() {
                        guard !Task.isCancelled else { return }
                        delay = retryDelay
                        apply(value)
                    }
                } catch {
                    print("Day subscription failed: \(error)")
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    /// A `nil` means signed out, which says nothing about the day, so cached targets stay.
    private func apply(_ answer: TargetsAnswer?, to key: String) {
        guard let answer else { return }
        switch answer {
        case .noProfile:
            record(for: key).hasNoProfile = true
            // Progress is measured against targets, and without a profile its query answers `nil`.
            update(key) {
                $0.targets = nil
                $0.progress = nil
            }
        case .targets(let targets):
            record(for: key).hasNoProfile = false
            update(key) { $0.targets = targets }
        }
    }

    private func update(_ key: String, _ change: (inout DaySnapshot) -> Void) {
        change(&record(for: key).snapshot)
        scheduleSave()
    }

    /// A day's queries answer together, so this waits and writes them once. Older days stay in
    /// memory for the page showing them, but only recent ones are worth saving.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            let known = records.filter { !$0.value.snapshot.isEmpty }
            // Keys are "YYYY-MM-DD", so they sort by date.
            let recent = known.keys.sorted(by: >).prefix(Self.maxSavedDays)
            let saved = known.filter { recent.contains($0.key) }.mapValues(\.snapshot)
            let fileURL = fileURL
            fileQueue.async {
                do {
                    try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
                } catch {
                    print("Saving days failed: \(error)")
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var dayStore = DayStore.shared
}
