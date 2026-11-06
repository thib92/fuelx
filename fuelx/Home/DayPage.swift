import SwiftUI

/// One day: calories and macros against the target, meals, and activity.
struct DayPage: View {
    let day: Date
    let isToday: Bool
    let onSetUpProfile: () -> Void

    @Environment(\.dayStore) private var store
    @State private var addingTo: MealKind?
    @State private var isShowingTargetDetails = false

    private var entries: DayEntries? { store[day].entries }
    private var workoutDay: WorkoutDay? { store[day].workouts }
    private var workouts: [Workout] { workoutDay?.workouts ?? [] }

    var body: some View {
        List {
            overviewSection

            Section {
                ForEach(MealKind.allCases) { meal in
                    mealRow(meal)
                }
            } header: {
                SectionTitle(title: "Meals", trailing: "kcal")
            }

            Section {
                activityRows
            } header: {
                SectionTitle(title: "Activity")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $addingTo) { meal in
            AddFoodSheet(day: day, meal: meal)
        }
        .sheet(isPresented: $isShowingTargetDetails) {
            if let targets = store.targets(for: day).loaded {
                TargetDetailsSheet(targets: targets, workouts: workouts)
            }
        }
        .task(id: day) { await store.watch(.day(day)) }
    }

    private func mealRow(_ meal: MealKind) -> some View {
        HStack(spacing: 4) {
            NavigationLink(value: MealRoute(day: day, meal: meal)) {
                MealRow(
                    meal: meal,
                    entries: entries?.entries(for: meal) ?? [],
                    kcal: Int(entries?.mealTotals[meal].kcal ?? 0))
            }
            .navigationLinkIndicatorVisibility(.hidden)
            Button("Add Food to \(meal.label)", systemImage: "plus") { addingTo = meal }
                .labelStyle(.iconOnly)
                .font(.subheadline.bold())
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.2), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .buttonStyle(.borderless)
        }
        .listRowInsets(.vertical, 4)
    }

    @ViewBuilder
    private var overviewSection: some View {
        switch store.targets(for: day) {
        case .loaded(let targets):
            overview(targets)
        case .noProfile:
            Section {
                Button(action: onSetUpProfile) {
                    Label("Set Up Your Daily Targets", systemImage: "target")
                }
            } footer: {
                Text("Get calorie, protein, carb and fat targets based on your body and goal.")
            }
        case .loading:
            overview(.placeholder)
                .redacted(reason: .placeholder)
                .disabled(true)
        }
    }

    private func overview(_ targets: NutritionTargets) -> some View {
        Section {
            DayOverview(
                targets: targets,
                eaten: entries?.totals,
                isToday: isToday,
                onShowDetails: { isShowingTargetDetails = true })
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var activityRows: some View {
        if !HealthSync.shared.isConnected {
            Button("Connect Apple Health", systemImage: "heart") {
                Task { await HealthSync.shared.connect() }
            }
        } else if workouts.isEmpty {
            LabeledContent {
                if let steps = workoutDay?.steps {
                    Text("\(Int(steps)) steps")
                        .monospacedDigit()
                }
            } label: {
                Label("Rest day", systemImage: "bed.double")
            }
            .redacted(reason: workoutDay == nil ? .placeholder : [])
        }
        ForEach(workouts) { WorkoutRow(workout: $0) }
        if !workouts.isEmpty, let steps = workoutDay?.steps {
            LabeledContent {
                Text(Int(steps).formatted())
                    .monospacedDigit()
            } label: {
                Label("Steps", systemImage: "figure.walk")
            }
        }
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey
    var trailing: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color(.label))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
            }
        }
        .textCase(nil)
    }
}

/// A meal's calories and a preview of its foods.
private struct MealRow: View {
    let meal: MealKind
    let entries: [LogEntry]
    let kcal: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meal.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.label)
                    .font(.headline)
                if !entries.isEmpty {
                    Text(entries.map(\.name).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if kcal > 0 {
                Text(kcal.formatted())
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title)
                    Text(workout.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: workout.sport.systemImage)
            }
            Spacer()
            Text("+\(workout.caloriesBurned.kcal)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DayPage(day: Days.today, isToday: true, onSetUpProfile: {})
}
