import Foundation

/// What the app last knew about a day. Convex keeps nothing on disk, so without this every launch
/// would start empty.
nonisolated struct DaySnapshot: Codable, Sendable {
    var targets: NutritionTargets?
    var entries: DayEntries?
    var workouts: WorkoutDay?
    var progress: DayProgress?
}

/// Recent days, so pages open with real numbers in their first frame and refresh once Convex
/// answers. Held in memory, so reads are safe while a view initializes, and saved to Caches, which
/// isn't backed up and which the system may empty: all of it can be fetched again.
///
/// It belongs to the current session: ``AuthModel`` clears it whenever the account changes.
final class DayCache {
    static let shared = DayCache()

    /// Covers this week and last week's strip.
    private static let maxDays = 14
    private static let saveDelay: Duration = .milliseconds(300)
    /// Bump when a cached model changes, though a file that no longer decodes is simply ignored.
    private nonisolated static let fileURL = URL.cachesDirectory.appending(path: "day-cache-v1.json")

    private var days: [String: DaySnapshot]
    private var pendingSave: Task<Void, Never>?
    /// Keeps file operations in order, so a save can't bring data back after `clear()`.
    private let fileQueue = DispatchQueue(label: "dev.thenry.fuelx.day-cache", qos: .utility)

    private init() {
        let data = try? Data(contentsOf: Self.fileURL)
        days = data.flatMap { try? JSONDecoder().decode([String: DaySnapshot].self, from: $0) } ?? [:]
    }

    subscript(day: Date) -> DaySnapshot? { days[Days.key(for: day)] }

    func update(_ day: Date, _ change: (inout DaySnapshot) -> Void) {
        change(&days[Days.key(for: day), default: DaySnapshot()])
        // Keys are "YYYY-MM-DD", so they sort by date.
        for key in days.keys.sorted(by: >).dropFirst(Self.maxDays) {
            days[key] = nil
        }
        scheduleSave()
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        days = [:]
        fileQueue.async {
            try? FileManager.default.removeItem(at: Self.fileURL)
        }
    }

    /// A day's queries answer together, so this waits and writes them once.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            let days = self.days
            self.fileQueue.async {
                do {
                    try JSONEncoder().encode(days).write(to: Self.fileURL, options: .atomic)
                } catch {
                    print("Saving the day cache failed: \(error)")
                }
            }
        }
    }
}
