import SwiftUI

/// Choose how much of a food to log, with live nutrition for that amount.
struct AmountView: View {
    let food: FoodResult
    let primaryTitle: LocalizedStringKey
    /// Shows a Delete button when set.
    let onDelete: (() async throws -> Void)?
    let onSubmit: (Double) async throws -> Void

    @State private var grams: Double
    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let quickAmounts: [Double] = [50, 100, 150, 200]

    init(
        food: FoodResult,
        initialGrams: Double,
        primaryTitle: LocalizedStringKey,
        onDelete: (() async throws -> Void)? = nil,
        onSubmit: @escaping (Double) async throws -> Void
    ) {
        self.food = food
        self.primaryTitle = primaryTitle
        self.onDelete = onDelete
        self.onSubmit = onSubmit
        _grams = State(initialValue: initialGrams)
    }

    private var canSave: Bool { grams > 0 && !isSaving }

    /// Preview only: the backend computes the logged values.
    private func amount(_ per100g: Double) -> Double { per100g * grams / 100 }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Amount", value: $grams, format: .number)
                        .keyboardType(.decimalPad)
                    Text("g").foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack {
                        if let servingG = food.servingG {
                            Button("1 serving") { grams = servingG }
                        }
                        ForEach(Self.quickAmounts, id: \.self) { amount in
                            Button("\(amount.formatted()) g") { grams = amount }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .scrollIndicators(.hidden)
            } header: {
                Text("Amount")
            }

            Section {
                LabeledContent("Calories", value: Int(amount(food.per100g.kcal).rounded()).kcal)
                LabeledContent("Protein", value: amount(food.per100g.proteinG).grams)
                LabeledContent("Carbs", value: amount(food.per100g.carbsG).grams)
                LabeledContent("Fat", value: amount(food.per100g.fatG).grams)
            } header: {
                Text("For This Amount")
            }

            if let onDelete {
                Section {
                    Button("Delete", systemImage: "trash", role: .destructive) { perform(onDelete) }
                        .disabled(isSaving)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(food.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(primaryTitle) { perform { try await onSubmit(grams) } }
                    .disabled(!canSave)
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await ConnectionMonitor.shared.ensureConnected()
                try await action()
            } catch {
                errorMessage = error.convexMessage
            }
        }
    }
}
