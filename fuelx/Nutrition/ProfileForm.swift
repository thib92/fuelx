import Combine
import ConvexMobile
import SwiftUI

/// Edits the inputs behind the daily calorie and macro targets (`profile:upsert`).
struct ProfileForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthModel.self) private var auth

    @State private var sex: Sex?
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    @State private var heightCm: Double?
    @State private var weightKg: Double?
    @State private var activityLevel = ActivityLevel.sedentary
    @State private var goal = WeightGoal.maintain
    @State private var goalRate = 0.0
    @State private var proteinGPerKg = 1.6
    @State private var fatPercent = 25.0

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -100, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -13, to: .now) ?? .now
        return oldest...youngest
    }

    private var canSave: Bool {
        sex != nil && (heightCm ?? 0) > 0 && (weightKg ?? 0) > 0 && !isSaving && !isLoading
    }

    var body: some View {
        Form {
            Section {
                Picker("Sex", selection: $sex) {
                    ForEach(Sex.allCases) { Text($0.label).tag(Sex?.some($0)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                DatePicker("Birth date", selection: $birthDate, in: birthDateRange, displayedComponents: .date)
                measurementField("Height", value: $heightCm, unit: "cm")
                measurementField("Weight", value: $weightKg, unit: "kg")
            } header: {
                Text("About You")
            } footer: {
                Text("Used to estimate your resting energy with the Mifflin-St Jeor equation.")
            }

            Section {
                Picker("Activity level", selection: $activityLevel) {
                    ForEach(ActivityLevel.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.label)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Daily Activity")
            } footer: {
                Text("Your everyday activity outside of training. Workouts don't count toward your targets yet.")
            }

            Section {
                Picker("Goal", selection: $goal) {
                    ForEach(WeightGoal.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if goal != .maintain {
                    Picker("Rate", selection: $goalRate) {
                        ForEach(goal.rates, id: \.self) { rate in
                            Text("\(rate.formatted()) kg per week").tag(rate)
                        }
                    }
                }
            } header: {
                Text("Weight Goal")
            } footer: {
                if goal == .lose {
                    Text("Calories never go below your resting energy, and loss is capped at 1% of body weight per week.")
                }
            }

            Section {
                Stepper(value: $proteinGPerKg, in: 1.2...2.0, step: 0.1) {
                    LabeledContent("Protein", value: "\(proteinGPerKg.formatted(.number.precision(.fractionLength(1)))) g/kg")
                }
                Stepper(value: $fatPercent, in: 20...35, step: 1) {
                    LabeledContent("Fat", value: String(localized: "\(Int(fatPercent))% of calories"))
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Protein is set per kg of body weight, fat as a share of calories, and carbs get the rest. Sports nutrition guidelines suggest 1.2–2.0 g/kg of protein and 20–35% fat.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Nutrition Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .onChange(of: goal) { _, goal in
            if !goal.rates.contains(goalRate) { goalRate = goal.rates.first ?? 0 }
        }
        .disabled(isLoading)
        .overlay { if isLoading { ProgressView() } }
        // Until there's a session, Convex answers as if there were no profile, and saving fails.
        .task(id: auth.session) {
            guard isLoading, auth.session != nil else { return }
            await load()
        }
    }

    private func measurementField(_ title: LocalizedStringKey, value: Binding<Double?>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(unit, value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            for try await profile in convex.subscribe(to: "profile:get", yielding: NutritionProfile?.self).values {
                if let profile { apply(profile) }
                break
            }
        } catch {
            errorMessage = error.convexMessage
        }
        // Cancelled means the session changed, and the next load takes over.
        if !Task.isCancelled { isLoading = false }
    }

    private func apply(_ profile: NutritionProfile) {
        sex = profile.sex
        birthDate = Days.date(fromKey: profile.birthDate) ?? birthDate
        heightCm = profile.heightCm
        weightKg = profile.weightKg
        activityLevel = profile.activityLevel
        goal = profile.goal
        goalRate = profile.goalRateKgPerWeek
        proteinGPerKg = profile.proteinGPerKg
        fatPercent = profile.fatPercent
    }

    private func save() async {
        guard let sex, let heightCm, let weightKg else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await ConnectionMonitor.shared.ensureConnected()
            // Every number is sent as a Double: Swift Ints encode as Convex int64, which
            // `v.number()` rejects.
            try await convex.mutation("profile:upsert", with: [
                "sex": sex.rawValue,
                "birthDate": Days.key(for: birthDate),
                "heightCm": heightCm,
                "weightKg": weightKg,
                "activityLevel": activityLevel.rawValue,
                "goal": goal.rawValue,
                "goalRateKgPerWeek": goal == .maintain ? 0.0 : goalRate,
                "proteinGPerKg": (proteinGPerKg * 10).rounded() / 10,
                "fatPercent": fatPercent.rounded(),
            ])
            dismiss()
        } catch {
            errorMessage = error.convexMessage
        }
    }
}

#Preview {
    NavigationStack { ProfileForm() }
        .environment(AuthModel(client: convex, api: betterAuth))
}
