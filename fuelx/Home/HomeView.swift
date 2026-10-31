import SwiftUI

/// Browse days: swipe between them, tap the week strip, or jump with the calendar.
struct HomeView: View {
    /// Two years of history, oldest first, ending today.
    @State private var days = Days.lastDays(730)
    /// Drives the pager. Can be briefly nil mid-swipe, so the UI reads `currentDay` instead.
    @State private var scrolledDay: Date? = Days.today
    @State private var currentDay = Days.today
    @State private var isShowingCalendar = false
    @State private var isShowingAccount = false

    private var today: Date { days.last ?? Days.today }
    private var isOnToday: Bool { currentDay == today }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekStrip(selectedDay: currentDay, availableDays: (days.first ?? today)...today) { day in
                    show(day, animated: true)
                }

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            DayPage(log: MockDayLogs.log(for: day))
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledDay)
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: scrolledDay) { _, day in
                if let day { currentDay = day }
            }
            .navigationTitle(Days.title(for: currentDay))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnToday {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { show(today, animated: true) }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Go to Day", systemImage: "calendar") {
                        isShowingCalendar = true
                    }
                    Button("Account", systemImage: "person.crop.circle") {
                        isShowingAccount = true
                    }
                }
            }
            .sheet(isPresented: $isShowingCalendar) {
                DayPickerSheet(day: currentDay, availableDays: (days.first ?? today)...today) { day in
                    show(day, animated: false)
                }
            }
            .sheet(isPresented: $isShowingAccount) {
                AccountView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func show(_ day: Date, animated: Bool) {
        let day = Days.calendar.startOfDay(for: day)
        guard day != currentDay else { return }
        currentDay = day
        if animated {
            withAnimation { scrolledDay = day }
        } else {
            scrolledDay = day
        }
    }
}

#Preview {
    HomeView()
        .environment(AuthModel(client: convex, api: betterAuth))
}
