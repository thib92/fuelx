import ConvexMobile
import SwiftUI

/// Create a private food by hand when nothing matches.
struct CustomFoodForm: View {
    let onCreated: (FoodResult) -> Void

    @State private var name: String
    @State private var brand = ""
    @State private var kcal: Double?
    @State private var proteinG: Double?
    @State private var carbsG: Double?
    @State private var fatG: Double?
    @State private var servingG: Double?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(name: String, onCreated: @escaping (FoodResult) -> Void) {
        _name = State(initialValue: name)
        self.onCreated = onCreated
    }

    private var per100g: Per100g? {
        guard let kcal, let proteinG, let carbsG, let fatG else { return nil }
        return Per100g(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedBrand: String { brand.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedName.isEmpty && per100g != nil && !isSaving }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Brand (optional)", text: $brand)
            }

            Section {
                number("Calories", value: $kcal, unit: "kcal")
                number("Protein", value: $proteinG, unit: "g")
                number("Carbs", value: $carbsG, unit: "g")
                number("Fat", value: $fatG, unit: "g")
            } header: {
                Text("Per 100 g")
            }

            Section {
                number("One serving (optional)", value: $servingG, unit: "g")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("New Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue", action: save)
                    .disabled(!canSave)
            }
        }
    }

    private func number(_ title: LocalizedStringKey, value: Binding<Double?>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        guard let per100g else { return }
        isSaving = true
        errorMessage = nil
        // Optional arguments are left out: a nil value would be sent as null, which they reject.
        var args: [String: ConvexEncodable?] = [
            "name": trimmedName,
            "per100g": [
                "kcal": per100g.kcal,
                "proteinG": per100g.proteinG,
                "carbsG": per100g.carbsG,
                "fatG": per100g.fatG,
            ] as [String: ConvexEncodable?],
        ]
        if !trimmedBrand.isEmpty { args["brand"] = trimmedBrand }
        if let servingG { args["servingG"] = servingG }

        Task {
            defer { isSaving = false }
            do {
                let id: String = try await convex.mutation("foods:createCustom", with: args)
                onCreated(FoodResult(
                    id: id,
                    name: trimmedName,
                    brand: trimmedBrand.isEmpty ? nil : trimmedBrand,
                    per100g: per100g,
                    servingG: servingG))
            } catch {
                errorMessage = error.convexMessage
            }
        }
    }
}
