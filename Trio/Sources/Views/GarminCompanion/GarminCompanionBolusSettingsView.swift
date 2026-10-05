import Combine
import SwiftUI
import Swinject

/// Settings for bolusing from the Trio Companion Garmin watch app.
struct GarminCompanionBolusSettingsView: View {
    @AppStorage(GarminCompanionBolusSettings.enabledKey) private var isEnabled = false
    @AppStorage(GarminCompanionBolusSettings.maxBolusKey) private var maxBolus = GarminCompanionBolusSettings.defaultMaxBolus
    @AppStorage(GarminCompanionBolusSettings.maxCarbsKey) private var maxCarbs = GarminCompanionBolusSettings.defaultMaxCarbs

    @State private var pin = ""
    @State private var hasPIN = false
    @State private var isPaired = false
    @State private var pairingSeconds = 0
    @State private var failures = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var pumpMaxBolus: Decimal? { TrioApp.resolver.resolve(SettingsManager.self)?.pumpSettings.maxBolus }

    var body: some View {
        Form {
            Section(
                header: Text("Watch Bolus"),
                footer: Text(
                    "Lets the paired Trio Companion app on your Garmin watch request a bolus and log carbs. Trio still applies Max Bolus, Max IOB, Max Carbs and the recent-bolus check, plus the watch limits below, and notifies you of every watch bolus."
                )
            ) {
                Toggle("Allow Bolus from Garmin", isOn: Binding(
                    get: { isEnabled },
                    set: { on in
                        isEnabled = on && isPaired
                        if on { GarminCompanionBolusSettings.authFailures = 0 }
                        refresh()
                    }
                ))
                    .disabled(!isPaired && !isEnabled)
                if !isPaired {
                    Text("Pair your watch first.").font(.footnote).foregroundColor(.secondary)
                } else if failures >= GarminCompanionBolusSettings.maxAuthFailures {
                    Text("Turned off after \(failures) requests with a wrong PIN or key.")
                        .font(.footnote).foregroundColor(.red)
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("Watch Limits"),
                footer: Text(pumpMaxBolusFooter)
            ) {
                Stepper(value: $maxBolus, in: 0.5 ... 10, step: 0.5) {
                    HStack {
                        Text("Max per watch bolus")
                        Spacer()
                        Text("\(maxBolus, specifier: "%.1f") U").foregroundColor(.secondary)
                    }
                }
                Stepper(value: $maxCarbs, in: 5 ... 150, step: 5) {
                    HStack {
                        Text("Max carbs per watch entry")
                        Spacer()
                        Text("\(maxCarbs, specifier: "%.0f") g").foregroundColor(.secondary)
                    }
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("PIN"),
                footer: Text("4 digits, used only to pair the watch. Kept on this iPhone and not synced to iCloud.")
            ) {
                SecureField(hasPIN ? "PIN saved – enter to change" : "Enter PIN", text: $pin)
                    .keyboardType(.numberPad)
                Button("Save PIN") { savePIN() }
                    .disabled(!GarminCompanionBolusSettings.isValidPIN(pin))
                if hasPIN {
                    Button("Remove PIN", role: .destructive) {
                        GarminCompanionBolusSettings.pin = nil
                        GarminCompanionBolusSettings.closePairing()
                        refresh()
                    }
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("Pairing"),
                footer: Text(
                    "Tap Pair Watch, then on the watch open Trio Companion, hold UP for the menu, choose Pair with Trio and enter the PIN within 2 minutes. Trio then gives the watch its own random key; the PIN isn't sent with bolus requests."
                )
            ) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(isPaired ? "Paired" : pairingSeconds > 0 ? "Waiting for watch… \(pairingSeconds) s" : "Not paired")
                        .foregroundColor(isPaired ? .green : .secondary)
                }
                if pairingSeconds > 0 {
                    Button("Cancel Pairing") {
                        GarminCompanionBolusSettings.closePairing()
                        refresh()
                    }
                } else {
                    Button(isPaired ? "Pair Again" : "Pair Watch") {
                        GarminCompanionBolusSettings.openPairing()
                        refresh()
                    }
                    .disabled(!hasPIN)
                }
                if isPaired {
                    Button("Unpair Watch", role: .destructive) {
                        GarminCompanionBolusSettings.unpair()
                        refresh()
                    }
                }
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Garmin Watch Bolus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Older builds kept the PIN in the iCloud-synced keychain; drop that copy.
            TrioApp.resolver.resolve(Keychain.self)?.removeObject(forKey: GarminCompanionBolusSettings.legacyPinKey)
            refresh()
        }
        .onReceive(tick) { _ in refresh() }
    }

    private var pumpMaxBolusFooter: String {
        let base =
            String(
                localized: "Requests above these are rejected even if they're under your pump's Max Bolus or Trio's Max Carbs."
            )
        guard let pumpMaxBolus else { return base }
        return base + " " +
            String(localized: "Pump Max Bolus: \(NSDecimalNumber(decimal: pumpMaxBolus).doubleValue, specifier: "%.1f") U.")
    }

    private func refresh() {
        hasPIN = GarminCompanionBolusSettings.pin != nil
        isPaired = GarminCompanionBolusSettings.isPaired
        pairingSeconds = GarminCompanionBolusSettings.pairingSecondsLeft
        failures = GarminCompanionBolusSettings.authFailures
        if !isPaired, isEnabled { isEnabled = false }
    }

    private func savePIN() {
        guard GarminCompanionBolusSettings.isValidPIN(pin) else { return }
        GarminCompanionBolusSettings.pin = pin
        pin = ""
        refresh()
    }
}
