import Foundation

/// Day arithmetic and labels. Days are represented by their start-of-day `Date`.
enum Days {
    static var calendar: Calendar { .current }

    static var today: Date { calendar.startOfDay(for: .now) }

    /// The last `count` days, oldest first, ending today.
    static func lastDays(_ count: Int) -> [Date] {
        let today = today
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// First day of the week containing `day`, honoring the user's first weekday.
    static func startOfWeek(for day: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
    }

    /// The 7 days of the week containing `day`.
    static func week(containing day: Date) -> [Date] {
        let start = startOfWeek(for: day)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Start of every week overlapping `days`, oldest first.
    static func weekStarts(covering days: ClosedRange<Date>) -> [Date] {
        let first = startOfWeek(for: days.lowerBound)
        let last = startOfWeek(for: days.upperBound)
        let count = calendar.dateComponents([.weekOfYear], from: first, to: last).weekOfYear ?? 0
        return (0...max(count, 0)).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: first) }
    }

    /// Whole days from `from` to `to` (negative if `to` is earlier).
    static func distance(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// "Today", "Yesterday", "Monday, Oct 27", or "Monday, Oct 27, 2025" for other years.
    static func title(for day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let format = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        return calendar.isDate(day, equalTo: .now, toGranularity: .year)
            ? day.formatted(format)
            : day.formatted(format.year())
    }
}

extension Days {
    /// "YYYY-MM-DD" for `day` in the user's time zone: how the backend identifies a day.
    static func key(for day: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Parses a "YYYY-MM-DD" key back into a start-of-day `Date`.
    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension Int {
    /// "1,234 kcal"
    var kcal: String { "\(formatted()) kcal" }
}

extension Double {
    /// "32.5 g"
    var grams: String { "\(formatted(.number.precision(.fractionLength(0...1)))) g" }
}
