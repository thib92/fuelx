import Combine
import ConvexMobile
import SwiftUI

/// Swipeable week strip. Tapping a day selects it; swiping to another week selects the same
/// weekday there (capped to the available range). Follows `selectedDay` when it moves to
/// another week, animating to adjacent weeks.
struct WeekStrip: View {
    let selectedDay: Date
    let availableDays: ClosedRange<Date>
    /// The day to show, and whether the day pager should animate to it.
    let onSelect: (_ day: Date, _ animated: Bool) -> Void

    private let weeks: [Date]
    @State private var scrolledWeek: Date?
    @State private var isUserScrolling = false

    init(
        selectedDay: Date,
        availableDays: ClosedRange<Date>,
        onSelect: @escaping (_ day: Date, _ animated: Bool) -> Void
    ) {
        self.selectedDay = selectedDay
        self.availableDays = availableDays
        self.onSelect = onSelect
        weeks = Days.weekStarts(covering: availableDays)
        _scrolledWeek = State(initialValue: Days.startOfWeek(for: selectedDay))
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weeks, id: \.self) { weekStart in
                    WeekRow(
                        weekStart: weekStart,
                        selectedDay: selectedDay,
                        availableDays: availableDays,
                        onSelect: onSelect
                    )
                    .padding(.horizontal)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledWeek)
        .scrollIndicators(.hidden)
        // Horizontal scroll views take all offered height; size to the row instead.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting:
                isUserScrolling = true
            case .idle where isUserScrolling:
                isUserScrolling = false
                selectSameWeekdayInScrolledWeek()
            default:
                break
            }
        }
        .onChange(of: selectedDay) { _, day in
            let week = Days.startOfWeek(for: day)
            guard week != scrolledWeek else { return }
            let isAdjacentWeek = scrolledWeek.map { abs(Days.distance(from: $0, to: week)) <= 7 } ?? false
            if isAdjacentWeek {
                withAnimation { scrolledWeek = week }
            } else {
                scrolledWeek = week
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    private func selectSameWeekdayInScrolledWeek() {
        let selectedWeek = Days.startOfWeek(for: selectedDay)
        guard let week = scrolledWeek, week != selectedWeek else { return }
        let weekdayOffset = Days.distance(from: selectedWeek, to: selectedDay)
        let day = Days.calendar.date(byAdding: .day, value: weekdayOffset, to: week) ?? week
        onSelect(min(max(day, availableDays.lowerBound), availableDays.upperBound), false)
    }
}

/// One week of days, each ringed by how much of its target was eaten.
private struct WeekRow: View {
    let weekStart: Date
    let selectedDay: Date
    let availableDays: ClosedRange<Date>
    let onSelect: (_ day: Date, _ animated: Bool) -> Void

    @Environment(AuthModel.self) private var auth

    /// Keyed by day. Empty while loading or without targets, which leaves the rings off.
    @State private var progress: [String: DayProgress]

    init(
        weekStart: Date,
        selectedDay: Date,
        availableDays: ClosedRange<Date>,
        onSelect: @escaping (_ day: Date, _ animated: Bool) -> Void
    ) {
        self.weekStart = weekStart
        self.selectedDay = selectedDay
        self.availableDays = availableDays
        self.onSelect = onSelect
        let cached = Days.week(containing: weekStart).compactMap { DayCache.shared[$0]?.progress }
        _progress = State(initialValue: Dictionary(cached.map { ($0.day, $0) }) { _, last in last })
    }

    /// The last available day changes at midnight, and with it which day is in progress.
    private var liveWeek: LiveWeek {
        LiveWeek(lastDay: availableDays.upperBound, session: auth.session)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Days.week(containing: weekStart), id: \.self) { day in
                dayButton(day)
            }
        }
        .task(id: liveWeek) {
            guard auth.session != nil else { return }
            let days: [ConvexEncodable?] = Days.week(containing: weekStart)
                .filter(availableDays.contains)
                .map(Days.key(for:))
            guard !days.isEmpty else { return }
            let updates = convex.subscribe(
                to: "nutrition:progressForDays",
                with: ["days": days, "today": Days.key(for: availableDays.upperBound)],
                yielding: [DayProgress]?.self)
            do {
                for try await value in updates.values {
                    guard let value else { continue }
                    progress = Dictionary(value.map { ($0.day, $0) }) { _, last in last }
                    for item in value {
                        guard let day = Days.date(fromKey: item.day) else { continue }
                        DayCache.shared.update(day) { $0.progress = item }
                    }
                }
            } catch {
                print("nutrition:progressForDays failed: \(error)")
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = Days.calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = Days.calendar.isDateInToday(day)
        let isAvailable = availableDays.contains(day)

        return Button {
            onSelect(day, true)
        } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isSelected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(Color(.systemBackground))
                            : isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay {
                        if let fraction = progress[Days.key(for: day)]?.fraction {
                            DayProgressRing(fraction: fraction)
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.3)
        .accessibilityLabel(Days.title(for: day))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LiveWeek: Hashable {
    let lastDay: Date
    let session: UUID?
}

private struct DayProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemFill), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(
                    fraction > 1 ? AnyShapeStyle(.red) : AnyShapeStyle(.tint),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(1.25)
    }
}
