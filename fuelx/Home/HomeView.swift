import SwiftUI

/// Browse days: swipe between them, tap the week strip, or jump with the calendar.
struct HomeView: View {
    /// Two years of history, oldest first, ending today.
    @State private var days = Days.lastDays(730)
    /// Drives the pager. Can be nil or pass through other days mid-scroll, so the UI reads
    /// `currentDay`, which only follows the pager once scrolling settles.
    @State private var scrolledDay: Date? = Days.today
    @State private var currentDay = Days.today
    @State private var isShowingCalendar = false
    @State private var isShowingAccount = false
    @State private var isShowingProfile = false

    private var today: Date { days.last ?? Days.today }
    private var isOnToday: Bool { currentDay == today }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekStrip(selectedDay: currentDay, availableDays: (days.first ?? today)...today) { day, animated in
                    show(day, animated: animated)
                }

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            DayPage(log: MockDayLogs.log(for: day)) { isShowingProfile = true }
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledDay)
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
                .onScrollPhaseChange { _, phase in
                    if phase == .idle, let scrolledDay, scrolledDay != currentDay {
                        currentDay = scrolledDay
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Days.title(for: currentDay))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        // Animating across many pages looks like a blur; jump instead.
                        show(today, animated: Days.distance(from: currentDay, to: today) <= 7)
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
            .sheet(isPresented: $isShowingProfile) {
                NavigationStack {
                    ProfileForm()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { isShowingProfile = false }
                            }
                        }
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
