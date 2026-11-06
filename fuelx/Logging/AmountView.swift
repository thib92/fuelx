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
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        stepButton("Remove 10 g", systemImage: "minus") { grams = max(grams - 10, 0) }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            TextField("Amount", value: $grams, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 130)
                            Text("g")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        stepButton("Add 10 g", systemImage: "plus") { grams += 10 }
                    }
                    ViewThatFits(in: .horizontal) {
                        quickAmountButtons
                        ScrollView(.horizontal) { quickAmountButtons }
                            .scrollIndicators(.hidden)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(.horizontal, 0)

            Section {
                LabeledContent("Calories", value: Int(amount(food.per100g.kcal).rounded()).kcal)
                macroRow(.carbs, per100g: food.per100g.carbsG)
                macroRow(.protein, per100g: food.per100g.proteinG)
                macroRow(.fat, per100g: food.per100g.fatG)
            } header: {
                Text("For This Amount")
            }

            if let onDelete {
                Section {
                    Button(role: .destructive) { perform(onDelete) } label: {
                        Text("Delete").frame(maxWidth: .infinity)
                    }
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

    private func stepButton(
        _ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.fill.tertiary, in: .circle)
            .contentShape(.circle)
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
    }

    private var quickAmountButtons: some View {
        HStack(spacing: 8) {
            if let servingG = food.servingG {
                quickAmountButton("1 serving", grams: servingG)
            }
            ForEach(Self.quickAmounts, id: \.self) { amount in
                quickAmountButton("\(amount.formatted()) g", grams: amount)
            }
        }
    }

    private func quickAmountButton(_ title: LocalizedStringKey, grams: Double) -> some View {
        Button { self.grams = grams } label: {
            Text(title)
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.fill.tertiary, in: .capsule)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private func macroRow(_ macro: Macro, per100g: Double) -> some View {
        LabeledContent {
            Text(amount(per100g).grams)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(macro.color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(macro.label)
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
