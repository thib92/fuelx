import Foundation
import Observation
import SwiftUI

/// What the app knows about a day, whether it came from disk or from Convex.
nonisolated struct DaySnapshot: Codable, Sendable {
    var targets: NutritionTargets?
    var entries: DayEntries?
    var workouts: WorkoutDay?
    var progress: DayProgress?
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

/// Day data, cached and live. Views read a day with `store[day]`, keep it fresh with
/// `store.watch(_:)`, and never need to know where the numbers came from.
///
/// Reads are synchronous, so pages have real numbers in their first frame. The recent days are
/// saved to Caches, which isn't backed up and which the system may empty: all of it can be fetched
/// again. Convex keeps nothing on disk itself.
///
/// The data belongs to the current session, so ``AuthModel`` reports session changes here and
/// clears the store when the account changes.
@Observable
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
    }

    static let shared = DayStore(source: ConvexDayData(), fileURL: DayStore.defaultFileURL)

    /// Bump the name when a cached model changes, though a file that no longer decodes is ignored.
    private nonisolated static let defaultFileURL = URL.cachesDirectory
        .appending(path: "day-cache-v1.json")
    /// Covers this week and last week's strip.
    private static let maxSavedDays = 14

    private(set) var days: [String: DaySnapshot]
    private var daysWithoutProfile: Set<String> = []

    @ObservationIgnored private let source: DayDataSource
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private let stopDelay: Duration
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var subscriptions: [Watch: Subscription] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Keeps file operations in order, so a save can't bring data back after `clear()`.
    @ObservationIgnored private let fileQueue = DispatchQueue(
        label: "dev.thenry.fuelx.day-store", qos: .utility)

    /// - Parameter stopDelay: Swiping recreates pages constantly, so a day stays subscribed this
    ///   long after its last view leaves.
    init(
        source: DayDataSource,
        fileURL: URL,
        saveDelay: Duration = .milliseconds(300),
        stopDelay: Duration = .seconds(10)
    ) {
        self.source = source
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.stopDelay = stopDelay
        let data = try? Data(contentsOf: fileURL)
        days = data.flatMap { try? JSONDecoder().decode([String: DaySnapshot].self, from: $0) } ?? [:]
    }

    subscript(day: Date) -> DaySnapshot {
        days[Days.key(for: day)] ?? DaySnapshot()
    }

    func targets(for day: Date) -> DayTargets {
        let key = Days.key(for: day)
        if daysWithoutProfile.contains(key) { return .noProfile }
        return days[key]?.targets.map(DayTargets.loaded) ?? .loading
    }

    /// Keeps `watch` fresh until the calling task is cancelled, as `.task` does when its view
    /// leaves. Waits for a session: until then Convex answers as if signed out.
    func watch(_ watch: Watch) async {
        retain(watch)
        defer { release(watch) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Restarts subscriptions, so they answer for the new session.
    func sessionDidChange(_ session: UUID?) {
        self.session = session
        for (watch, subscription) in subscriptions {
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
    }

    /// Forgets everything, for when the account changes.
    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        days = [:]
        daysWithoutProfile = []
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

    private func start(_ watch: Watch) {
        guard session != nil else { return }
        switch watch {
        case .day(let day):
            let key = Days.key(for: day)
            subscriptions[watch]?.tasks = [
                listen(to: source.targets(for: day)) { [weak self] in self?.apply($0, to: key) },
                // These are only `nil` when signed out, which says nothing about the day.
                listen(to: source.entries(for: day)) { [weak self] value in
                    guard let value else { return }
                    self?.update(key) { $0.entries = value }
                },
                listen(to: source.workouts(for: day)) { [weak self] value in
                    guard let value else { return }
                    self?.update(key) { $0.workouts = value }
                },
            ]
        case .progress(let days, let today):
            subscriptions[watch]?.tasks = [
                listen(to: source.progress(for: days, today: today)) { [weak self] value in
                    for item in value ?? [] {
                        self?.update(item.day) { $0.progress = item }
                    }
                }
            ]
        }
    }

    /// Drops anything that arrives after cancellation, which may belong to the previous session.
    private func listen<Value>(
        to updates: AsyncThrowingStream<Value, Error>,
        apply: @escaping (Value) -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await value in updates {
                    guard !Task.isCancelled else { return }
                    apply(value)
                }
            } catch {
                print("Day subscription failed: \(error)")
            }
        }
    }

    private func apply(_ targets: NutritionTargets?, to key: String) {
        if targets == nil {
            daysWithoutProfile.insert(key)
        } else {
            daysWithoutProfile.remove(key)
        }
        update(key) { $0.targets = targets }
    }

    private func update(_ key: String, _ change: (inout DaySnapshot) -> Void) {
        change(&days[key, default: DaySnapshot()])
        scheduleSave()
    }

    /// A day's queries answer together, so this waits and writes them once. Older days stay in
    /// memory for the page showing them, but only recent ones are worth saving.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            // Keys are "YYYY-MM-DD", so they sort by date.
            let recent = days.keys.sorted(by: >).prefix(Self.maxSavedDays)
            let saved = days.filter { recent.contains($0.key) }
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
