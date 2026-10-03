import CoreData
import CryptoKit
import Foundation
import Swinject

// Bolus and carb requests from the Trio Companion Garmin watch app
// (github: k9track/trio-garmin-companion). Lives outside GarminManager so upstream
// merges into that file stay small; GarminManager only routes messages here.
//
// Wire format, watch → phone (a Connect IQ dictionary):
//   t   "bolus"
//   id  random request id (hex string, 8–32 chars)
//   u   insulin in hundredths of a unit (Int), 0 for carbs only
//   c   carbs in grams (Int), 0 for insulin only
//   ts  watch time, unix seconds (Int)
//   sig lowercase hex HMAC-SHA256 of "bolus|<id>|<u>|<c>|<ts>", keyed with the PIN
//
// Phone → watch: ["t": "bolusAck", "id": id, "ok": Bool, "stage": String, "msg": String]
// stage is "rejected", "delivering", "done" or "failed".

enum GarminCompanionBolusSettings {
    static let enabledKey = "GarminCompanionBolus.enabled"
    static let maxBolusKey = "GarminCompanionBolus.maxBolus"
    static let pinKey = "GarminCompanionBolus.pin"
    static let defaultMaxBolus: Double = 3

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Watch-only cap. The pump's Max Bolus, Max IOB and the recent-bolus check
    /// still apply on top of it.
    static var maxBolus: Decimal {
        let value = UserDefaults.standard.object(forKey: maxBolusKey) as? Double ?? defaultMaxBolus
        return Decimal(value)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}

@MainActor final class GarminCompanionBolusHandler {
    typealias Reply = ([String: Any]) -> Void

    /// How far the watch clock may be from the phone's, in either direction.
    static let maxClockSkew: TimeInterval = 60

    private static let lastAcceptedKey = "GarminCompanionBolus.lastAcceptedTimestamp"

    private var seenIDs: [String: Date] = [:]
    private var inFlight = false

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
                  let id = message["id"] as? String,
                  (8 ... 32).contains(id.count),
                  id.allSatisfy(\.isHexDigit),
                  let u = (message["u"] as? NSNumber)?.intValue,
                  let c = (message["c"] as? NSNumber)?.intValue,
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

    /// True if the message is a bolus request, whether or not it is accepted.
    nonisolated static func isBolusRequest(_ message: Any) -> Bool {
        (message as? [String: Any])?["t"] as? String == "bolus"
    }

    func handle(_ message: Any, reply: @escaping Reply) async {
        let rawID = (message as? [String: Any])?["id"] as? String ?? ""

        func reject(_ msg: String, id: String = rawID) {
            debug(.watchManager, "Garmin bolus: rejected \(id): \(msg)")
            reply(["t": "bolusAck", "id": id, "ok": false, "stage": "rejected", "msg": msg])
        }

        guard GarminCompanionBolusSettings.isEnabled else {
            return reject("Watch bolus is off in Trio")
        }
        let savedPIN: String? = resolver.resolve(Keychain.self)?
            .getValue(String.self, forKey: GarminCompanionBolusSettings.pinKey)
        guard let pin = savedPIN, GarminCompanionBolusSettings.isValidPIN(pin) else {
            return reject("No PIN set in Trio")
        }
        guard let message = message as? [String: Any], let request = Request(message: message) else {
            return reject("Bad request")
        }
        guard Self.isSignatureValid(request, pin: pin) else {
            return reject("Wrong PIN")
        }

        // Replay protection: recent, never seen, and not older than the last one accepted.
        let now = Date()
        let sentAt = Date(timeIntervalSince1970: TimeInterval(request.timestamp))
        guard abs(now.timeIntervalSince(sentAt)) <= Self.maxClockSkew else {
            return reject("Request expired. Check the watch time.")
        }
        seenIDs = seenIDs.filter { now.timeIntervalSince($0.value) < Self.maxClockSkew * 5 }
        guard seenIDs[request.id] == nil else {
            return reject("Duplicate request")
        }
        seenIDs[request.id] = now
        let lastAccepted = UserDefaults.standard.integer(forKey: Self.lastAcceptedKey)
        guard request.timestamp >= lastAccepted else {
            return reject("Out-of-order request")
        }

        guard !inFlight else {
            return reject("Another watch request is in progress")
        }
        inFlight = true
        defer { inFlight = false }

        if let error = await validateAmounts(request, sentAt: sentAt) {
            return reject(error)
        }

        // Accepted. Nothing below may be retried by replaying this request.
        UserDefaults.standard.set(request.timestamp, forKey: Self.lastAcceptedKey)
        debug(
            .watchManager,
            "Garmin bolus: accepted \(request.id): \(request.units) U, \(request.carbs) g"
        )

        if request.carbs > 0 {
            do {
                try await saveCarbs(request.carbs)
            } catch {
                debug(.watchManager, "Garmin bolus: saving carbs failed: \(error)")
                reply(["t": "bolusAck", "id": request.id, "ok": false, "stage": "failed", "msg": "Couldn't save carbs"])
                return
            }
        }

        guard request.centiUnits > 0 else {
            reply(["t": "bolusAck", "id": request.id, "ok": true, "stage": "done", "msg": "\(request.carbs) g logged"])
            return
        }

        guard let apsManager = resolver.resolve(APSManager.self) else {
            reply(["t": "bolusAck", "id": request.id, "ok": false, "stage": "failed", "msg": "Trio isn't ready"])
            return
        }

        reply(["t": "bolusAck", "id": request.id, "ok": true, "stage": "delivering", "msg": "Delivering \(request.units) U"])
        await apsManager.enactBolus(amount: NSDecimalNumber(decimal: request.units).doubleValue, isSMB: false) { success, msg in
            debug(.watchManager, "Garmin bolus: \(request.id) \(success ? "started" : "failed"): \(msg)")
            reply([
                "t": "bolusAck",
                "id": request.id,
                "ok": success,
                "stage": success ? "done" : "failed",
                "msg": success ? "Bolus started" : msg
            ])
        }
    }

    nonisolated static func isSignatureValid(_ request: Request, pin: String) -> Bool {
        guard let signature = Data(hexString: request.signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: Data(request.signedString.utf8),
            using: SymmetricKey(data: Data(pin.utf8))
        )
    }

    /// Returns a message for the watch if the amounts aren't allowed, nil if they are.
    private func validateAmounts(_ request: Request, sentAt: Date) async -> String? {
        guard request.centiUnits >= 0, request.carbs >= 0, request.centiUnits + request.carbs > 0 else {
            return "Nothing to deliver"
        }

        if request.carbs > 0 {
            let maxCarbs = resolver.resolve(SettingsManager.self)?.settings.maxCarbs ?? 0
            guard Decimal(request.carbs) <= maxCarbs else {
                return "Over max carbs (\(maxCarbs) g)"
            }
        }

        guard request.centiUnits > 0 else { return nil }

        let watchCap = GarminCompanionBolusSettings.maxBolus
        guard request.units <= watchCap else {
            return "Over watch max (\(watchCap) U)"
        }

        guard let validator = resolver.resolve(BolusSafetyValidator.self) else {
            return "Trio isn't ready"
        }
        // Count any bolus since the watch sent this, and at least the usual window.
        let usualStart = Date().addingTimeInterval(-Double(BolusSafetyEvaluator.recentBolusWindowMinutes * 60))
        do {
            switch try await validator.validate(bolusAmount: request.units, lookbackStart: min(sentAt, usualStart)) {
            case .allowed:
                return nil
            case let .rejected(reason):
                return reason.watchMessage
            }
        } catch {
            return "Couldn't check recent boluses"
        }
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
}
