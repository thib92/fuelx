import SwiftUI

/// The week around the selected day. Tapping a day selects it; future days are disabled.
struct WeekStrip: View {
    let selectedDay: Date
    let availableDays: ClosedRange<Date>
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Days.week(containing: selectedDay), id: \.self) { day in
                dayButton(day)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = Days.calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = Days.calendar.isDateInToday(day)
        let isAvailable = availableDays.contains(day)

        return Button {
            onSelect(day)
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
                    .frame(width: 36, height: 36)
                    .background {
                        if isSelected {
                            Circle().fill(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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
