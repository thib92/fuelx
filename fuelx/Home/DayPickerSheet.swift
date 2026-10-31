import SwiftUI

/// Calendar for jumping to any past day.
struct DayPickerSheet: View {
    let availableDays: ClosedRange<Date>
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(day: Date, availableDays: ClosedRange<Date>, onSelect: @escaping (Date) -> Void) {
        self.availableDays = availableDays
        self.onSelect = onSelect
        _selection = State(initialValue: day)
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $selection, in: availableDays, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Go to Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .onChange(of: selection) { _, day in
                    onSelect(day)
                    dismiss()
                }
        }
        .presentationDetents([.medium])
    }
}
