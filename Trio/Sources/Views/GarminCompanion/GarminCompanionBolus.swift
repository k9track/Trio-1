import CoreData
import CryptoKit
import Foundation
import Swinject
import UserNotifications

// Bolus and carb requests from the Trio Companion Garmin watch app
// (github: k9track/trio-garmin-companion, PROTOCOL.md). Lives outside GarminManager
// so upstream merges into that file stay small; GarminManager only routes messages here.
//
// Pairing (once): the user opens a 2-minute window in Trio and enters the 4-digit PIN
// on the watch, which sends
//   ["t": "pair", "id": hex, "ts": unix s, "sig": HMAC-SHA256(PIN, "pair|<id>|<ts>")]
// Trio answers with a random 256-bit key:
//   ["t": "pairAck", "id": id, "ok": true, "key": 64 hex chars]
// The PIN is never used again; a captured request can't be brute-forced back to a key.
//
// Requests:
//   ["t": "bolus", "id": hex, "u": centi-units, "c": grams, "ts": unix s,
//    "sig": HMAC-SHA256(key, "bolus|<id>|<u>|<c>|<ts>")]
// Replies: ["t": "bolusAck", "id": id, "ok": Bool, "stage": String, "msg": String]
// stage: "rejected" (nothing saved or delivered), "delivering", "done", or "failed"
// (outcome uncertain, the watch says to check Trio).

enum GarminCompanionBolusSettings {
    static let enabledKey = "GarminCompanionBolus.enabled"
    static let maxBolusKey = "GarminCompanionBolus.maxBolus"
    static let maxCarbsKey = "GarminCompanionBolus.maxCarbs"
    static let failuresKey = "GarminCompanionBolus.authFailures"
    static let pairingUntilKey = "GarminCompanionBolus.pairingUntil"
    static let defaultMaxBolus: Double = 3
    static let defaultMaxCarbs: Double = 60
    /// Wrong PINs or signatures in a row before watch bolus switches itself off.
    static let maxAuthFailures = 5
    static let pairingWindow: TimeInterval = 120

    /// Older builds kept the PIN in the iCloud-synced keychain under this name.
    static let legacyPinKey = "GarminCompanionBolus.pin"
    private static let pinKey = "GarminCompanionBolus.pin.local"
    private static let watchKeyKey = "GarminCompanionBolus.watchKey"

    /// This device only, never synced to iCloud, readable after first unlock so
    /// requests work while the phone is locked in a pocket.
    private static let keychain = BaseKeychain(
        synchronizable: false,
        accessibilityLevel: .afterFirstUnlockThisDeviceOnly
    )

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Watch-only caps. The pump's Max Bolus, Max IOB, Trio's Max Carbs and the
    /// recent-bolus check still apply on top of them.
    static var maxBolus: Decimal {
        Decimal(UserDefaults.standard.object(forKey: maxBolusKey) as? Double ?? defaultMaxBolus)
    }

    static var maxCarbs: Decimal {
        Decimal(UserDefaults.standard.object(forKey: maxCarbsKey) as? Double ?? defaultMaxCarbs)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isASCIIDigit)
    }

    static var pin: String? {
        get {
            let value: String? = keychain.getValue(String.self, forKey: pinKey)
            return value.flatMap { isValidPIN($0) ? $0 : nil }
        }
        set {
            if let newValue { keychain.setValue(newValue, forKey: pinKey) }
            else { keychain.removeObject(forKey: pinKey) }
        }
    }

    /// The random key the paired watch signs requests with.
    static var watchKey: SymmetricKey? {
        let hex: String? = keychain.getValue(String.self, forKey: watchKeyKey)
        guard let hex, hex.count == 64, let data = Data(hexString: hex) else { return nil }
        return SymmetricKey(data: data)
    }

    static var isPaired: Bool { watchKey != nil }

    /// Makes and stores a new key; returns it as hex for the watch.
    static func makeWatchKey() -> String {
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { Data($0) }.hexString
        keychain.setValue(hex, forKey: watchKeyKey)
        return hex
    }

    static func unpair() {
        keychain.removeObject(forKey: watchKeyKey)
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    static var isPairingOpen: Bool {
        Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: pairingUntilKey)
    }

    static var pairingSecondsLeft: Int {
        max(0, Int(UserDefaults.standard.double(forKey: pairingUntilKey) - Date().timeIntervalSince1970))
    }

    static func openPairing() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + pairingWindow, forKey: pairingUntilKey)
    }

    static func closePairing() {
        UserDefaults.standard.set(0, forKey: pairingUntilKey)
    }

    static var authFailures: Int {
        get { UserDefaults.standard.integer(forKey: failuresKey) }
        set { UserDefaults.standard.set(newValue, forKey: failuresKey) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}

@MainActor final class GarminCompanionBolusHandler {
    typealias Reply = ([String: Any]) -> Void

    /// How far the watch clock may be from the phone's, in either direction.
    static let maxClockSkew: TimeInterval = 60
    /// Request bounds, far above any real dose; anything larger is malformed.
    nonisolated static let maxCentiUnits = 10000
    nonisolated static let maxCarbGrams = 1000

    private static let lastAcceptedKey = "GarminCompanionBolus.lastAcceptedTimestamp"
    private static let rejectedNotAuthorized = "Not authorized"

    private var seenIDs: [String: Date] = [:]
    private var inFlight = false
    /// Watch boluses started in the last few minutes, in case the pump event
    /// isn't stored yet when the next request is checked.
    private var recentWatchBoluses: [(date: Date, units: Decimal)] = []

    nonisolated init() {}

    private var resolver: Resolver { TrioApp.resolver }

    struct Request: Equatable {
        let id: String
        let centiUnits: Int
        let carbs: Int
        let timestamp: Int
        let signature: String

        var units: Decimal { Decimal(centiUnits) / 100 }
        var signedString: String { "bolus|\(id)|\(centiUnits)|\(carbs)|\(timestamp)" }

        init?(message: [String: Any]) {
            guard message["t"] as? String == "bolus",
                  let id = message["id"] as? String, GarminCompanionBolusHandler.isValidID(id),
                  let u = (message["u"] as? NSNumber)?.intValue,
                  let c = (message["c"] as? NSNumber)?.intValue,
                  (0 ... GarminCompanionBolusHandler.maxCentiUnits).contains(u),
                  (0 ... GarminCompanionBolusHandler.maxCarbGrams).contains(c),
                  let ts = (message["ts"] as? NSNumber)?.intValue,
                  let sig = message["sig"] as? String
            else { return nil }
            self.id = id
            centiUnits = u
            carbs = c
            timestamp = ts
            signature = sig.lowercased()
        }
    }

    struct PairRequest {
        let id: String
        let timestamp: Int
        let signature: String
        var signedString: String { "pair|\(id)|\(timestamp)" }

        init?(message: [String: Any]) {
            guard message["t"] as? String == "pair",
                  let id = message["id"] as? String, GarminCompanionBolusHandler.isValidID(id),
                  let ts = (message["ts"] as? NSNumber)?.intValue,
                  let sig = message["sig"] as? String
            else { return nil }
            self.id = id
            timestamp = ts
            signature = sig.lowercased()
        }
    }

    nonisolated static func isValidID(_ id: String) -> Bool {
        (8 ... 32).contains(id.count) && id.allSatisfy(\.isHexDigit)
    }

    /// True for messages this handler owns (bolus or pairing), whether or not they're accepted.
    nonisolated static func isCompanionRequest(_ message: Any) -> Bool {
        let type = (message as? [String: Any])?["t"] as? String
        return type == "bolus" || type == "pair"
    }

    func handle(_ message: Any, reply: @escaping Reply) async {
        guard let dict = message as? [String: Any] else { return }
        if dict["t"] as? String == "pair" {
            handlePair(dict, reply: reply)
        } else {
            await handleBolus(dict, reply: reply)
        }
    }

    // MARK: - Pairing

    private func handlePair(_ message: [String: Any], reply: @escaping Reply) {
        let rawID = message["id"] as? String ?? ""
        func reject(_ msg: String) {
            debug(.watchManager, "Garmin pairing: rejected: \(msg)")
            reply(["t": "pairAck", "id": rawID, "ok": false, "msg": msg])
        }

        guard GarminCompanionBolusSettings.isPairingOpen else {
            return reject("Tap Pair watch in Trio first")
        }
        guard let pin = GarminCompanionBolusSettings.pin else {
            return reject("Set a PIN in Trio first")
        }
        guard let request = PairRequest(message: message) else {
            return reject("Bad request")
        }
        guard Self.isSignatureValid(request.signature, for: request.signedString, key: SymmetricKey(data: Data(pin.utf8)))
        else {
            recordAuthFailure()
            return reject("Wrong PIN")
        }
        guard isFresh(request.timestamp), seenIDs[request.id] == nil else {
            return reject("Request expired. Check the watch time.")
        }
        seenIDs[request.id] = Date()

        let key = GarminCompanionBolusSettings.makeWatchKey()
        GarminCompanionBolusSettings.closePairing()
        GarminCompanionBolusSettings.authFailures = 0
        debug(.watchManager, "Garmin pairing: watch paired")
        notify("Garmin watch paired", "Trio Companion on your watch can now send bolus requests.")
        reply(["t": "pairAck", "id": request.id, "ok": true, "key": key, "msg": "Paired"])
    }

    // MARK: - Bolus

    private func handleBolus(_ message: [String: Any], reply: @escaping Reply) async {
        let rawID = message["id"] as? String ?? ""
        func reject(_ msg: String, id: String = rawID) {
            debug(.watchManager, "Garmin bolus: rejected \(id): \(msg)")
            reply(["t": "bolusAck", "id": id, "ok": false, "stage": "rejected", "msg": msg])
        }

        guard GarminCompanionBolusSettings.isEnabled else {
            return reject("Watch bolus is off in Trio")
        }
        guard let key = GarminCompanionBolusSettings.watchKey else {
            return reject("Watch not paired with Trio")
        }
        guard let request = Request(message: message) else {
            return reject("Bad request")
        }
        guard Self.isSignatureValid(request.signature, for: request.signedString, key: key) else {
            recordAuthFailure()
            return reject(Self.rejectedNotAuthorized)
        }
        GarminCompanionBolusSettings.authFailures = 0

        // Replay protection: recent, never seen, and newer than the last one accepted.
        guard isFresh(request.timestamp) else {
            return reject("Request expired. Check the watch time.")
        }
        guard seenIDs[request.id] == nil else {
            return reject("Duplicate request")
        }
        seenIDs[request.id] = Date()
        let lastAccepted = UserDefaults.standard.integer(forKey: Self.lastAcceptedKey)
        guard request.timestamp > lastAccepted else {
            return reject("Out-of-order request")
        }

        guard !inFlight else {
            return reject("Another watch request is in progress")
        }
        inFlight = true
        defer { inFlight = false }

        let sentAt = Date(timeIntervalSince1970: TimeInterval(request.timestamp))
        let units: Decimal
        switch await validateAmounts(request, sentAt: sentAt) {
        case let .failure(error):
            return reject(error.message)
        case let .success(rounded):
            units = rounded
        }

        // Accepted. Stored no later than now so a fast watch clock can't block later requests.
        let now = Int(Date().timeIntervalSince1970)
        UserDefaults.standard.set(min(request.timestamp, now), forKey: Self.lastAcceptedKey)
        debug(.watchManager, "Garmin bolus: accepted \(request.id): \(units) U, \(request.carbs) g")

        if request.carbs > 0 {
            do {
                try await saveCarbs(request.carbs)
            } catch {
                debug(.watchManager, "Garmin bolus: saving carbs failed: \(error)")
                reply(["t": "bolusAck", "id": request.id, "ok": false, "stage": "rejected", "msg": "Couldn't save carbs"])
                return
            }
        }

        guard units > 0 else {
            notify("Carbs from Garmin watch", "\(request.carbs) g logged.")
            reply(["t": "bolusAck", "id": request.id, "ok": true, "stage": "done", "msg": "\(request.carbs) g logged"])
            return
        }

        guard let apsManager = resolver.resolve(APSManager.self) else {
            let msg = request.carbs > 0 ? "Carbs logged, bolus not sent. Don't resend carbs." : "Trio isn't ready"
            reply([
                "t": "bolusAck",
                "id": request.id,
                "ok": false,
                "stage": request.carbs > 0 ? "failed" : "rejected",
                "msg": msg
            ])
            return
        }

        let carbs = request.carbs
        reply(["t": "bolusAck", "id": request.id, "ok": true, "stage": "delivering", "msg": "Delivering \(units) U"])
        await apsManager
            .enactBolus(amount: NSDecimalNumber(decimal: units).doubleValue, isSMB: false) { [weak self] success, msg in
                debug(.watchManager, "Garmin bolus: \(request.id) \(success ? "started" : "failed"): \(msg)")
                if success {
                    Task { @MainActor in self?.recentWatchBoluses.append((Date(), units)) }
                    self?.notify(
                        "Bolus from Garmin watch",
                        "\(units) U started" + (carbs > 0 ? " with \(carbs) g carbs." : ".")
                    )
                    reply(["t": "bolusAck", "id": request.id, "ok": true, "stage": "done", "msg": "Bolus started"])
                } else {
                    let failure = carbs > 0
                        ? "Carbs logged, bolus failed. Check Trio; don't resend carbs."
                        : "Bolus failed. Check Trio before trying again."
                    reply(["t": "bolusAck", "id": request.id, "ok": false, "stage": "failed", "msg": failure])
                }
            }
    }

    struct Rejection: Error {
        let message: String
    }

    /// The rounded dose to deliver, or why the request isn't allowed.
    private func validateAmounts(_ request: Request, sentAt: Date) async -> Result<Decimal, Rejection> {
        guard request.centiUnits > 0 || request.carbs > 0 else {
            return .failure(Rejection(message: "Nothing to deliver"))
        }

        if request.carbs > 0 {
            let trioMax = resolver.resolve(SettingsManager.self)?.settings.maxCarbs ?? 0
            let maxCarbs = min(trioMax, GarminCompanionBolusSettings.maxCarbs)
            guard Decimal(request.carbs) <= maxCarbs else {
                return .failure(Rejection(message: "Over watch max carbs (\(maxCarbs) g)"))
            }
        }

        guard request.centiUnits > 0 else { return .success(0) }

        let watchCap = GarminCompanionBolusSettings.maxBolus
        guard request.units <= watchCap else {
            return .failure(Rejection(message: "Over watch max (\(watchCap) U)"))
        }

        guard let apsManager = resolver.resolve(APSManager.self),
              let validator = resolver.resolve(BolusSafetyValidator.self)
        else {
            return .failure(Rejection(message: "Trio isn't ready"))
        }
        // The pump rounds down to its own step; check and report what it will actually give.
        let units = apsManager.roundBolus(amount: request.units)
        guard units > 0 else {
            return .failure(Rejection(message: "Below the pump's smallest dose"))
        }

        let window = TimeInterval(BolusSafetyEvaluator.recentBolusWindowMinutes * 60)
        recentWatchBoluses.removeAll { Date().timeIntervalSince($0.date) > window }
        let recentWatch = recentWatchBoluses.reduce(Decimal(0)) { $0 + $1.units }
        if recentWatch >= units * BolusSafetyEvaluator.recentBolusThreshold {
            return .failure(Rejection(message: "A bolus was just given"))
        }

        // Count any bolus since the watch sent this, and at least the usual window.
        let usualStart = Date().addingTimeInterval(-window)
        do {
            switch try await validator.validate(bolusAmount: units, lookbackStart: min(sentAt, usualStart)) {
            case .allowed:
                return .success(units)
            case let .rejected(reason):
                return .failure(Rejection(message: reason.watchMessage))
            }
        } catch {
            return .failure(Rejection(message: "Couldn't check recent boluses"))
        }
    }

    // MARK: - Helpers

    private func isFresh(_ timestamp: Int) -> Bool {
        let now = Date()
        seenIDs = seenIDs.filter { now.timeIntervalSince($0.value) < Self.maxClockSkew * 5 }
        let sentAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return abs(now.timeIntervalSince(sentAt)) <= Self.maxClockSkew
    }

    /// Wrong PIN or signature. After a few in a row, watch bolus switches off until
    /// it's turned back on in Trio, and the user is told.
    private func recordAuthFailure() {
        GarminCompanionBolusSettings.authFailures += 1
        let failures = GarminCompanionBolusSettings.authFailures
        debug(.watchManager, "Garmin bolus: authentication failed (\(failures) in a row)")
        guard failures >= GarminCompanionBolusSettings.maxAuthFailures else { return }
        UserDefaults.standard.set(false, forKey: GarminCompanionBolusSettings.enabledKey)
        GarminCompanionBolusSettings.closePairing()
        notify(
            "Garmin watch bolus turned off",
            "\(failures) requests with a wrong PIN or key. Turn it back on in Trio's Garmin settings if this was you."
        )
    }

    nonisolated func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "GarminCompanion.\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    nonisolated static func isSignatureValid(_ signature: String, for string: String, key: SymmetricKey) -> Bool {
        guard let mac = Data(hexString: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(string.utf8), using: key)
    }

    private func saveCarbs(_ grams: Int) async throws {
        let context = CoreDataStack.shared.newTaskContext()
        try await context.perform {
            let carbEntry = CarbEntryStored(context: context)
            carbEntry.id = UUID()
            carbEntry.carbs = Double(grams)
            carbEntry.date = Date()
            carbEntry.note = "Via Garmin"
            carbEntry.isFPU = false
            carbEntry.isUploadedToNS = false
            carbEntry.isUploadedToHealth = false
            carbEntry.isUploadedToTidepool = false
            try context.save()
        }
    }
}

private extension BolusSafetyRejection {
    /// Short enough for a round watch screen.
    var watchMessage: String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return "Over max bolus (\(maxBolus) U)"
        case .iobUnavailable:
            return "IOB unavailable"
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return "Over max IOB (\(maxIOB) U, now \(currentIOB.rounded(toPlaces: 2)) U)"
        case .recentBolusWithinWindow:
            return "A bolus was just given"
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
