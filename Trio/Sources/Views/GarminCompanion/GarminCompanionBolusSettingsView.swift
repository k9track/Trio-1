import SwiftUI
import Swinject

/// Settings for bolusing from the Trio Companion Garmin watch app.
struct GarminCompanionBolusSettingsView: View {
    @AppStorage(GarminCompanionBolusSettings.enabledKey) private var isEnabled = false
    @AppStorage(GarminCompanionBolusSettings.maxBolusKey) private var maxBolus = GarminCompanionBolusSettings.defaultMaxBolus

    @State private var pin = ""
    @State private var hasSavedPIN = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var keychain: Keychain? { TrioApp.resolver.resolve(Keychain.self) }
    private var pumpMaxBolus: Decimal? { TrioApp.resolver.resolve(SettingsManager.self)?.pumpSettings.maxBolus }

    var body: some View {
        Form {
            Section(
                header: Text("Watch Bolus"),
                footer: Text(
                    "Lets the Trio Companion app on your Garmin watch request a bolus and log carbs. Trio still applies Max Bolus, Max IOB, Max Carbs and the recent-bolus check, plus the watch maximum below."
                )
            ) {
                Toggle("Allow Bolus from Garmin", isOn: $isEnabled)
                    .disabled(!hasSavedPIN && !isEnabled)
                if !hasSavedPIN {
                    Text("Set a PIN first.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("Watch Maximum Bolus"),
                footer: Text(pumpMaxBolusFooter)
            ) {
                Stepper(value: $maxBolus, in: 0.5 ... 10, step: 0.5) {
                    HStack {
                        Text("Max per watch bolus")
                        Spacer()
                        Text("\(maxBolus, specifier: "%.1f") U").foregroundColor(.secondary)
                    }
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("PIN"),
                footer: Text(
                    "4–6 digits. Enter the same PIN in the Trio Companion settings in the Garmin Connect app. Watch requests are signed with it and expire after 60 seconds."
                )
            ) {
                SecureField(hasSavedPIN ? "PIN saved – enter to change" : "Enter PIN", text: $pin)
                    .keyboardType(.numberPad)
                Button("Save PIN") { savePIN() }
                    .disabled(!GarminCompanionBolusSettings.isValidPIN(pin))
                if hasSavedPIN {
                    Button("Remove PIN", role: .destructive) { removePIN() }
                }
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Garmin Watch Bolus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let saved: String? = keychain?.getValue(String.self, forKey: GarminCompanionBolusSettings.pinKey)
            hasSavedPIN = saved.map(GarminCompanionBolusSettings.isValidPIN) ?? false
            if !hasSavedPIN { isEnabled = false }
        }
    }

    private var pumpMaxBolusFooter: String {
        let base = String(localized: "Requests above this are rejected even if they're under your pump's Max Bolus.")
        guard let pumpMaxBolus else { return base }
        return base + " " +
            String(localized: "Pump Max Bolus: \(NSDecimalNumber(decimal: pumpMaxBolus).doubleValue, specifier: "%.1f") U.")
    }

    private func savePIN() {
        guard GarminCompanionBolusSettings.isValidPIN(pin) else { return }
        keychain?.setValue(pin, forKey: GarminCompanionBolusSettings.pinKey)
        pin = ""
        hasSavedPIN = true
    }

    private func removePIN() {
        keychain?.removeObject(forKey: GarminCompanionBolusSettings.pinKey)
        hasSavedPIN = false
        isEnabled = false
    }
}
