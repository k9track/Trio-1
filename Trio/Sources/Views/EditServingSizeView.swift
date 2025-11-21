import SwiftUI

struct EditServingSizeView: View {
    @Binding var foodItem: FoodItem
    @Environment(\.dismiss) private var dismiss

    @State private var servingSizeText: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Food Item")
                        .font(.headline)
                    Text(foodItem.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Serving Size (grams)")
                        .font(.headline)

                    TextField("Enter serving size", text: $servingSizeText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.decimalPad)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nutritional Information")
                        .font(.headline)

                    let servingSize = Double(servingSizeText) ?? foodItem.servingSizeGrams
                    let tempItem = foodItem.withServingSize(servingSize)

                    HStack {
                        Text("Carbs:")
                        Spacer()
                        Text("\(tempItem.actualCarbs, specifier: "%.1f")g")
                    }

                    HStack {
                        Text("Protein:")
                        Spacer()
                        Text("\(tempItem.actualProtein, specifier: "%.1f")g")
                    }

                    HStack {
                        Text("Fat:")
                        Spacer()
                        Text("\(tempItem.actualFat, specifier: "%.1f")g")
                    }

                    HStack {
                        Text("Calories:")
                        Spacer()
                        Text("\(tempItem.actualCalories, specifier: "%.0f")")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)

                Spacer()
            }
            .padding()
            .navigationTitle("Edit Serving Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if let newServingSize = Double(servingSizeText) {
                            foodItem = foodItem.withServingSize(newServingSize)
                        }
                        dismiss()
                    }
                    .disabled(servingSizeText.isEmpty || Double(servingSizeText) == nil)
                }
            }
        }
        .onAppear {
            servingSizeText = String(format: "%.0f", foodItem.servingSizeGrams)
        }
    }
}

#Preview {
    @State var sampleItem = Treatments.FoodItem(
        barcode: "123456789",
        name: "Sample Food",
        brand: "Sample Brand",
        servingSize: "100g",
        carbsPer100g: 25.0,
        proteinPer100g: 10.0,
        fatPer100g: 5.0,
        caloriesPer100g: 180,
        servingSizeGrams: 100
    )

    return EditServingSizeView(foodItem: $sampleItem)
}
