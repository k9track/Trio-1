import Charts
import CoreData
import LoopKitUI
import Observation
import SwiftUI
import Swinject

extension Treatments {
    /// Represents a food item scanned via barcode with nutritional information
    struct FoodItem: Identifiable, Codable, Hashable {
        let id: UUID
        let barcode: String
        let name: String
        let brand: String?
        let servingSize: String?
        let carbsPer100g: Double
        let proteinPer100g: Double
        let fatPer100g: Double
        let caloriesPer100g: Double?
        let servingSizeGrams: Double?

        init(
            barcode: String,
            name: String,
            brand: String?,
            servingSize: String?,
            carbsPer100g: Double,
            proteinPer100g: Double,
            fatPer100g: Double,
            caloriesPer100g: Double?,
            servingSizeGrams: Double?
        ) {
            id = UUID()
            self.barcode = barcode
            self.name = name
            self.brand = brand
            self.servingSize = servingSize
            self.carbsPer100g = carbsPer100g
            self.proteinPer100g = proteinPer100g
            self.fatPer100g = fatPer100g
            self.caloriesPer100g = caloriesPer100g
            self.servingSizeGrams = servingSizeGrams
        }

        private init(
            id: UUID,
            barcode: String,
            name: String,
            brand: String?,
            servingSize: String?,
            carbsPer100g: Double,
            proteinPer100g: Double,
            fatPer100g: Double,
            caloriesPer100g: Double?,
            servingSizeGrams: Double?
        ) {
            self.id = id
            self.barcode = barcode
            self.name = name
            self.brand = brand
            self.servingSize = servingSize
            self.carbsPer100g = carbsPer100g
            self.proteinPer100g = proteinPer100g
            self.fatPer100g = fatPer100g
            self.caloriesPer100g = caloriesPer100g
            self.servingSizeGrams = servingSizeGrams
        }

        /// Calculated nutritional values for the actual serving
        var actualCarbs: Double {
            guard let servingSizeGrams = servingSizeGrams else { return carbsPer100g }
            return (carbsPer100g * servingSizeGrams) / 100.0
        }

        var actualProtein: Double {
            guard let servingSizeGrams = servingSizeGrams else { return proteinPer100g }
            return (proteinPer100g * servingSizeGrams) / 100.0
        }

        var actualFat: Double {
            guard let servingSizeGrams = servingSizeGrams else { return fatPer100g }
            return (fatPer100g * servingSizeGrams) / 100.0
        }

        var actualCalories: Double? {
            guard let caloriesPer100g = caloriesPer100g,
                  let servingSizeGrams = servingSizeGrams else { return caloriesPer100g }
            return (caloriesPer100g * servingSizeGrams) / 100.0
        }

        /// Display name for the food item
        var displayName: String {
            if let brand = brand, !brand.isEmpty {
                return "\(name) - \(brand)"
            }
            return name
        }

        /// Creates a food item with custom serving size
        func withServingSize(_ grams: Double) -> FoodItem {
            // Preserve the original ID to maintain identity in lists
            FoodItem(
                id: id,
                barcode: barcode,
                name: name,
                brand: brand,
                servingSize: "\(Int(grams))g",
                carbsPer100g: carbsPer100g,
                proteinPer100g: proteinPer100g,
                fatPer100g: fatPer100g,
                caloriesPer100g: caloriesPer100g,
                servingSizeGrams: grams
            )
        }
    }

    /// Observable class to manage a collection of scanned food items for meal planning
    @Observable class ScannedMealItems {
        var items: [FoodItem] = []

        /// Total carbohydrates from all scanned items
        var totalCarbs: Double {
            items.reduce(0) { $0 + $1.actualCarbs }
        }

        /// Total protein from all scanned items
        var totalProtein: Double {
            items.reduce(0) { $0 + $1.actualProtein }
        }

        /// Total fat from all scanned items
        var totalFat: Double {
            items.reduce(0) { $0 + $1.actualFat }
        }

        /// Total calories from all scanned items
        var totalCalories: Double {
            items.compactMap(\.actualCalories).reduce(0, +)
        }

        /// Generate a notes string for the meal
        var notesString: String {
            let itemNames = items.map(\.displayName)
            return "Scanned: " + itemNames.joined(separator: ", ")
        }

        /// Add a food item to the meal
        func addItem(_ item: FoodItem) {
            items.append(item)
        }

        /// Remove a food item from the meal
        func removeItem(_ item: FoodItem) {
            items.removeAll { $0.id == item.id }
        }

        /// Clear all items from the meal
        func clearAll() {
            items.removeAll()
        }

        /// Check if meal has any items
        var hasItems: Bool {
            !items.isEmpty
        }
    }

    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
        }

        @FocusState private var focusedField: FocusedField?

        let resolver: Resolver

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?

        // Barcode scanner states
        @State private var showScannedItemsSheet = false
        @State private var showBarcodeScanner = false
        @State private var scannedCode: String?
        @State private var scannedMeal = ScannedMealItems()
        @State private var showBarcodeNotFoundAlert = false
        // Serving size editor states
        @State private var editingItem: FoodItem?
        @State private var customServingSize: String = ""

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else { return 0 }
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        func handleDebouncedInput() {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task {
                    await state.updateForecasts()
                    state.insulinCalculated = await state.calculateInsulin()
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        /// Transfers scanned food items data to treatment fields
        private func addScannedItemsToTreatment() {
            // Add scanned totals to existing values
            let currentCarbs = Double(state.carbs)
            let currentProtein = Double(state.protein)
            let currentFat = Double(state.fat)

            state.carbs = Decimal(currentCarbs + scannedMeal.totalCarbs)
            state.protein = Decimal(currentProtein + scannedMeal.totalProtein)
            state.fat = Decimal(currentFat + scannedMeal.totalFat)

            // Add scanned items to notes
            let currentNote = state.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let scannedNotes = scannedMeal.notesString

            if currentNote.isEmpty {
                state.note = scannedNotes
            } else {
                state.note = currentNote + "; " + scannedNotes
            }

            // Clear scanned items after transfer
            scannedMeal.clearAll()

            // Update forecasts with new values
            handleDebouncedInput()
        }

        private func lookupFood(barcode: String) async {
            do {
                if let foodItem = try await FoodDatabaseService.shared.lookupFood(barcode: barcode) {
                    await MainActor.run {
                        // Prompt user to edit serving size before adding
                        editingItem = foodItem
                        customServingSize = String(foodItem.servingSizeGrams ?? 100)
                    }
                } else {
                    await MainActor.run {
                        // Handle case where product is not found
                        print("Product not found in database")
                        // Dismiss scanner and show a user-facing alert with options
                        showBarcodeScanner = false
                        showBarcodeNotFoundAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    // Handle error case
                    print("Error looking up food: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                scannedCode = nil
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                HStack {
                    Text("Protein")
                    TextFieldWithToolBar(
                        text: $state.protein,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .protein) },
                        nextTextField: { focusedField = nextField(from: .protein) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .protein)
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                HStack {
                    Text("Fat")
                    TextFieldWithToolBar(
                        text: $state.fat,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .fat) },
                        nextTextField: { focusedField = nextField(from: .fat) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .fat)
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) },
                    unitsText: String(localized: "g", comment: "Units for carbs")
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        ///
        /// This function handles the tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The next field that should receive focus, or nil if there is no next field
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .bolus
            case .protein:
                return .fat
            case .carbs:
                return showFPU ? .protein : .bolus
            case .bolus:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        ///
        /// This function handles the reverse tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The previous field that should receive focus, or nil if there is no previous field
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .carbs
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .fat : .carbs
            }
        }

        var body: some View {
            ZStack(alignment: .center) {
                VStack {
                    List {
                        Section {
                            ForecastChart(state: state)
                                .padding(.vertical)
                        }.listRowBackground(Color.chart)

                        Section {
                            carbsTextField()

                            if state.useFPUconversion {
                                proteinAndFat()
                            }

                            // Time
                            HStack {
                                // Semi-hacky workaround to make sure the List renders the horizontal divider properly between the `Time` and `Note` rows within the Section
                                HStack {
                                    Text("")
                                    Image(systemName: "clock").padding(.leading, -7)
                                }

                                Spacer()
                                if !pushed {
                                    Button {
                                        pushed = true
                                    } label: { Text("Now") }.buttonStyle(.borderless).foregroundColor(.secondary)
                                        .padding(.trailing, 5)
                                } else {
                                    Button { state.date = state.date.addingTimeInterval(-15.minutes.timeInterval) }
                                    label: { Image(systemName: "minus.circle") }.tint(.blue).buttonStyle(.borderless)

                                    DatePicker(
                                        "Time",
                                        selection: $state.date,
                                        displayedComponents: [.hourAndMinute]
                                    ).controlSize(.mini)
                                        .labelsHidden()
                                        .onChange(of: state.date) { _, _ in
                                            // Trigger simulation when date changes to update forecasts for backdated carbs
                                            Task {
                                                // `updateForecasts()` does update the `simulatedDetermination` of type `Determination?` var on the main thread, so I can use this to pass its cob value into the bolus calc manager
                                                await state.updateForecasts()
                                                state.insulinCalculated = await state.calculateInsulin()
                                            }
                                        }
                                    Button {
                                        state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                                    }
                                    label: { Image(systemName: "plus.circle") }.tint(.blue).buttonStyle(.borderless)
                                }
                            }

                            // Notes
                            HStack {
                                Image(systemName: "square.and.pencil")
                                TextFieldWithToolBarString(
                                    text: $state.note,
                                    placeholder: String(localized: "Note..."),
                                    maxLength: 25
                                )
                            }

                            // Barcode scanner button
                            HStack {
                                Button(action: {
                                    showBarcodeScanner = true
                                }) {
                                    HStack {
                                        Image(systemName: "barcode.viewfinder")
                                        Text("Scan Food Items")
                                    }
                                    .foregroundColor(.blue)
                                }
                                .buttonStyle(.borderless)

                                Spacer()

                                if scannedMeal.hasItems {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(scannedMeal.items.count) items")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("C: \(String(format: "%.1f", scannedMeal.totalCarbs))g")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }.listRowBackground(Color.chart)

                        Section {
                            if state.fattyMeals || state.sweetMeals {
                                HStack(spacing: 10) {
                                    if state.fattyMeals {
                                        Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                                            Text("Reduced Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useFattyMealCorrectionFactor) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useFattyMealCorrectionFactor {
                                                    state.useSuperBolus = false
                                                }
                                            }
                                        }
                                    }
                                    if state.sweetMeals {
                                        Toggle(isOn: $state.useSuperBolus) {
                                            Text("Super Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useSuperBolus) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useSuperBolus {
                                                    state.useFattyMealCorrectionFactor = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                HStack {
                                    Text("Recommendation")
                                    Button(action: {
                                        state.showInfo.toggle()
                                    }, label: {
                                        Image(systemName: "info.circle")
                                    })
                                        .foregroundStyle(.blue)
                                        .buttonStyle(PlainButtonStyle())
                                }
                                Spacer()
                                Button {
                                    state.amount = state.insulinCalculated
                                } label: {
                                    HStack {
                                        Text(
                                            formatter
                                                .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                                        )

                                        Text(
                                            String(
                                                localized:
                                                " U",
                                                comment: "Unit in number of units delivered (keep the space character!)"
                                            )
                                        ).foregroundColor(.secondary)
                                    }
                                }
                                .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                                .buttonStyle(.bordered).padding(.trailing, -10)
                            }

                            HStack {
                                Text("Bolus")
                                Spacer()
                                TextFieldWithToolBar(
                                    text: $state.amount,
                                    placeholder: "0",
                                    textColor: colorScheme == .dark ? .white : .blue,
                                    maxLength: 5,
                                    numberFormatter: formatter,
                                    showArrows: true,
                                    previousTextField: { focusedField = previousField(from: .bolus) },
                                    nextTextField: { focusedField = nextField(from: .bolus) },
                                    unitsText: String(localized: "U", comment: "Units for bolus amount")
                                ).focused($focusedField, equals: .bolus)
                                    .onChange(of: state.amount) {
                                        Task {
                                            await state.updateForecasts()
                                        }
                                    }
                            }

                            HStack {
                                Text("External Insulin")
                                Spacer()
                                Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                            }
                        }.listRowBackground(Color.chart)

                        treatmentButton
                    }
                    .listSectionSpacing(sectionSpacing)
                }
                .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
            }
            .padding(.top)
            .ignoresSafeArea(edges: .top)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .blur(radius: state.showInfo ? 3 : 0)
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if state.displayPresets {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showPresetSheet = true
                        }, label: {
                            HStack {
                                Text("Presets")
                                Image(systemName: "plus")
                            }
                        })
                    }
                }
            })
            .onAppear {
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.insulinCalculated = await state.calculateInsulin()
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .sheet(isPresented: $showPresetSheet, onDismiss: {
                showPresetSheet = false
            }) {
                MealPresetView(state: state)
            }
            .sheet(isPresented: $showBarcodeScanner) {
                BarcodeScannerView(scannedCode: $scannedCode, isPresented: $showBarcodeScanner)
            }
            .sheet(isPresented: $showScannedItemsSheet) {
                ScannedItemsView(
                    scannedMeal: scannedMeal,
                    onAddToTreatment: {
                        addScannedItemsToTreatment()
                        showScannedItemsSheet = false
                    }
                )
            }
            .sheet(item: $editingItem) { item in
                FractionalServingSizeView(
                    item: item,
                    onSave: { updatedItem in
                        scannedMeal.addItem(updatedItem)
                        showScannedItemsSheet = true
                    }
                )
            }
            .onChange(of: scannedCode) { _, newCode in
                if let code = newCode {
                    Task {
                        await lookupFood(barcode: code)
                    }
                }
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert) {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
            .alert(String(localized: "Product not found"), isPresented: $showBarcodeNotFoundAlert) {
                Button(String(localized: "Try Again")) {
                    showBarcodeScanner = true
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "No product found for that barcode. Please try again."))
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, state.carbs > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        struct FractionalServingSizeView: View {
            let item: FoodItem
            let onSave: (FoodItem) -> Void

            @Environment(\.dismiss) private var dismiss
            @State private var portions: Double = 1
            @State private var gramsPerPortion: Double = 100
            @State private var lastDelta: Double = 0
            @State private var showDelta: Bool = false
            @State private var defaultPortion: Double?

            var body: some View {
                NavigationView {
                    VStack(spacing: 20) {
                        Text(item.displayName)
                            .font(.title2)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Portions")
                                .font(.headline)
                            HStack {
                                // Use 0.5 as the minimum when stepping by 0.5 to avoid
                                // getting offset to 0.25 and producing values like 0.75/1.25
                                // that make 1.0 unreachable from certain paths.
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
                            HStack(spacing: 8) {
                                let quickOptions: [Double] = [0.5, 1.0, 1.5, 2.0]
                                ForEach(quickOptions, id: \.self) { opt in
                                    Button {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            portions = opt
                                        }
                                    } label: {
                                        Text(opt == floor(opt) ? "\(Int(opt))" : String(format: "%.1f", opt))
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                (abs(portions - opt) < 0.001) ? Color.blue
                                                    .opacity(0.15) : Color(.systemGray6)
                                            )
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                                if let defaultPortion, defaultPortion >= 0.5 {
                                    Text(
                                        "Default: " +
                                            (
                                                defaultPortion == floor(defaultPortion) ? "\(Int(defaultPortion))" :
                                                    String(format: "%.1f", defaultPortion)
                                            )
                                    )
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
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
                            Button("Cancel") { dismiss() }
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
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Save & Default") {
                                let totalGrams = gramsPerPortion * portions
                                let updatedItem = item.withServingSize(totalGrams)
                                let key = "defaultPortion_\(item.barcode)"
                                UserDefaults.standard.set(portions, forKey: key)
                                defaultPortion = portions
                                onSave(updatedItem)
                                dismiss()
                            }
                            .disabled(gramsPerPortion <= 0 || portions <= 0)
                        }
                    }
                    .onAppear {
                        gramsPerPortion = max(1, item.servingSizeGrams ?? 100)
                        let key = "defaultPortion_\(item.barcode)"
                        if let stored = UserDefaults.standard.object(forKey: key) as? Double, stored >= 0.5 {
                            let normalized = max(0.5, min(50, round(stored * 2) / 2))
                            portions = normalized
                            defaultPortion = normalized
                        } else if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
                            let stored = number.doubleValue
                            if stored >= 0.5 {
                                let normalized = max(0.5, min(50, round(stored * 2) / 2))
                                portions = normalized
                                defaultPortion = normalized
                            } else {
                                portions = 1
                            }
                        } else {
                            portions = 1
                        }
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

        @State private var showConfirmDialogForBolusing = false

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""

            let warningColor: Color = isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            var treatmentButtonBackground = Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                Button {
                    if bolusWarning.shouldConfirm {
                        showConfirmDialogForBolusing = true
                    } else {
                        state.invokeTreatmentsTask()
                    }
                } label: {
                    HStack {
                        if state.isBolusInProgress && state.amount > 0 &&
                            !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)
                        {
                            ProgressView()
                        }
                        taskButtonLabel
                    }
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 35)
                }
                .disabled(disableTaskButton)
                .listRowBackground(treatmentButtonBackground)
                .shadow(radius: 3)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .confirmationDialog(
                    bolusWarning.warningMessage + " Bolus \(state.amount.description) U?",
                    isPresented: $showConfirmDialogForBolusing,
                    titleVisibility: .visible
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button(
                        bolusWarning.warningMessage.isEmpty ? "Enact Bolus" : "Ignore Warning and Enact Bolus",
                        role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                    ) {
                        state.invokeTreatmentsTask()
                    }
                }
            } header: {
                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -22)
                }
            }
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            let hasInsulin = state.amount > 0
            let hasCarbs = state.carbs > 0
            let hasFatOrProtein = state.fat > 0 || state.protein > 0
            let bolusString = state.externalInsulin ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            if state.isBolusInProgress && hasInsulin && !state.externalInsulin && (!hasCarbs || !hasFatOrProtein) {
                return Text("Bolus In Progress...")
            }

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? "Log External Insulin" : "Enact Bolus")
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            state.carbs > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            state.fat > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            state.protein > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
        }

        private var disableTaskButton: Bool {
            (
                state.isBolusInProgress && state
                    .amount > 0 && !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)
            ) || state
                .addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}
