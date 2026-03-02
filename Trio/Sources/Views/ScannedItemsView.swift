import SwiftUI
import UIKit

struct ScannedItemsView: View {
    @Bindable var scannedMeal: Treatments.ScannedMealItems
    @State private var showingScanner = false
    @State private var scannedCode: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var editingItem: Treatments.FoodItem?
    @State private var customServingSize: String = ""
    @State private var showDuplicateWarning = false
    @State private var duplicateItemName: String = ""
    @State private var pendingFoodItem: Treatments.FoodItem?

    let onAddToTreatment: () -> Void

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with scan button
                headerView

                if scannedMeal.hasItems {
                    // Items list
                    itemsList

                    // Totals section
                    totalsSection

                    // Add to treatment button
                    addToTreatmentButton
                } else {
                    // Empty state
                    emptyStateView
                }
            }
            .navigationTitle("Scanned Items")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingScanner) {
                BarcodeScannerView(scannedCode: $scannedCode, isPresented: $showingScanner)
            }
            .sheet(item: $editingItem) { item in
                EditServingSizeView(
                    item: item,
                    customServingSize: $customServingSize,
                    onSave: { updatedItem in
                        updateItemServingSize(updatedItem)
                    }
                )
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Unknown error occurred")
            }
            .alert("Duplicate Item", isPresented: $showDuplicateWarning) {
                Button("Add Anyway") {
                    if let item = pendingFoodItem {
                        scannedMeal.addItem(item)
                        playSuccessHaptic()
                    }
                    pendingFoodItem = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingFoodItem = nil
                }
            } message: {
                Text("\(duplicateItemName) is already in your list. Add another?")
            }
            .onChange(of: scannedCode) { _, newCode in
                if let code = newCode {
                    Task {
                        await lookupFood(barcode: code)
                    }
                }
            }
            .overlay {
                if isLoading {
                    LoadingOverlay()
                }
            }
        }
    }

    private var headerView: some View {
        HStack {
            Button(action: {
                showingScanner = true
            }) {
                HStack {
                    Image(systemName: "barcode.viewfinder")
                    Text("Scan Barcode")
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.blue)
                .cornerRadius(10)
            }

            Spacer()

            if scannedMeal.hasItems {
                Button("Clear All") {
                    scannedMeal.clearAll()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
    }

    private var itemsList: some View {
        List {
            ForEach(scannedMeal.items) { item in
                FoodItemRow(item: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            scannedMeal.removeItem(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingItem = item
                            customServingSize = String(item.servingSizeGrams ?? 100)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(PlainListStyle())
    }

    private var totalsSection: some View {
        VStack(spacing: 8) {
            Text("Totals")
                .font(.headline)
                .padding(.top)

            HStack {
                NutrientTotal(label: "Carbs", value: scannedMeal.totalCarbs, unit: "g")
                Spacer()
                NutrientTotal(label: "Protein", value: scannedMeal.totalProtein, unit: "g")
                Spacer()
                NutrientTotal(label: "Fat", value: scannedMeal.totalFat, unit: "g")
            }
            .padding(.horizontal)

            if scannedMeal.totalCalories > 0 {
                Text("Total Calories: \(Int(scannedMeal.totalCalories))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var addToTreatmentButton: some View {
        Button(action: onAddToTreatment) {
            Text("Add to Treatment")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .cornerRadius(10)
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "barcode")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No items scanned yet")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("Tap 'Scan Barcode' to add food items")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private func lookupFood(barcode: String) async {
        isLoading = true
        errorMessage = nil

        do {
            if let foodItem = try await FoodDatabaseService.shared.lookupFood(barcode: barcode) {
                await MainActor.run {
                    // Check for duplicate barcode
                    if let existingItem = scannedMeal.items.first(where: { $0.barcode == foodItem.barcode }) {
                        duplicateItemName = existingItem.displayName
                        pendingFoodItem = foodItem
                        showDuplicateWarning = true
                        playWarningHaptic()
                    } else {
                        scannedMeal.addItem(foodItem)
                        playSuccessHaptic()
                    }
                }
            } else {
                await MainActor.run {
                    errorMessage = "Product not found in database"
                    showingError = true
                    playErrorHaptic()
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                playErrorHaptic()
            }
        }

        await MainActor.run {
            isLoading = false
            scannedCode = nil
        }
    }

    private func playSuccessHaptic() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
    }

    private func playWarningHaptic() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.warning)
    }

    private func playErrorHaptic() {
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.error)
    }

    private func updateItemServingSize(_ updatedItem: Treatments.FoodItem) {
        if let index = scannedMeal.items.firstIndex(where: { $0.id == updatedItem.id }) {
            scannedMeal.items[index] = updatedItem
        }
    }
}

struct FoodItemRow: View {
    let item: Treatments.FoodItem

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.headline)
                        .lineLimit(2)

                    if let servingSize = item.servingSize {
                        Text("Serving: \(servingSize)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            HStack(spacing: 16) {
                NutrientValue(label: "C", value: item.actualCarbs)
                NutrientValue(label: "P", value: item.actualProtein)
                NutrientValue(label: "F", value: item.actualFat)

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

struct NutrientValue: View {
    let label: String
    let value: Double

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(Self.numberFormatter.string(from: NSNumber(value: value)) ?? "0")
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct NutrientTotal: View {
    let label: String
    let value: Double
    let unit: String

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
            Text("\(Self.numberFormatter.string(from: NSNumber(value: value)) ?? "0") \(unit)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
    }
}

struct EditServingSizeView: View {
    let item: Treatments.FoodItem
    @Binding var customServingSize: String
    let onSave: (Treatments.FoodItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var portions: Double = 1
    @State private var gramsPerPortion: Double = 100
    @State private var lastDelta: Double = 0
    @State private var showDelta: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(item.displayName)
                    .font(.title2)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    // Portions selector (fractional, consistent with initial scan UI)
                    HStack {
                        Text("Portions")
                            .font(.headline)
                        Spacer()
                        Stepper(value: $portions, in: 0.5 ... 50, step: 0.5) {
                            Text(portions == floor(portions) ? "\(Int(portions))" : String(format: "%.1f", portions))
                        }
                        .labelsHidden()
                        Spacer()
                        Text("Per portion: \(Int(gramsPerPortion))g")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Visual feedback for +/− movements
                    if showDelta {
                        Text(String(format: "%+.1f portions", lastDelta))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                            .transition(.opacity)
                    }
                }

                let totalGrams = gramsPerPortion * portions
                if totalGrams > 0 {
                    let updatedItem = item.withServingSize(totalGrams)

                    // Summary of selection
                    HStack {
                        Text(String(format: "Total: %.1f portions", portions))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(Int(totalGrams))g total")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 12) {
                        Text("Nutritional Values")
                            .font(.headline)

                        HStack {
                            NutrientTotal(label: "Carbs", value: updatedItem.actualCarbs, unit: "g")
                            Spacer()
                            NutrientTotal(label: "Protein", value: updatedItem.actualProtein, unit: "g")
                            Spacer()
                            NutrientTotal(label: "Fat", value: updatedItem.actualFat, unit: "g")
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }

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
                        let totalGrams = gramsPerPortion * portions
                        let updatedItem = item.withServingSize(totalGrams)
                        onSave(updatedItem)
                        dismiss()
                    }
                    .disabled(gramsPerPortion <= 0 || portions <= 0)
                }
            }
            .onAppear {
                // Initialize grams per portion from item or provided binding (default to product's serving size)
                let initialGrams = Double(customServingSize) ?? item.servingSizeGrams ?? 100
                gramsPerPortion = max(1, initialGrams)
                portions = 1
            }
            .onChange(of: portions) { oldValue, newValue in
                // Normalize to nearest 0.5 to keep values stable and reversible
                let normalized = max(0.5, min(50, round(newValue * 2) / 2))
                if normalized != newValue {
                    portions = normalized
                }
                let oldNormalized = round(oldValue * 2) / 2
                lastDelta = normalized - oldNormalized
                withAnimation(.easeOut(duration: 0.2)) {
                    showDelta = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showDelta = false
                    }
                }
            }
        }
    }
}

struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Looking up product...")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 10)
        }
    }
}
