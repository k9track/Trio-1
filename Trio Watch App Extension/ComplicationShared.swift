import Foundation

// MARK: - Complication Data Model

/// Lightweight data shared between Watch App Extension and Watch Complication via App Group UserDefaults.
struct ComplicationData: Codable {
    let glucose: String
    let glucoseColorHex: String
    let trend: String?
    let delta: String?
    let iob: String?
    let cob: String?
    let lastLoopTime: String?
    let updatedAt: Date

    /// Whether the data is considered stale (older than 15 minutes)
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 15 * 60
    }
}

// MARK: - Complication Data Store

/// Reads and writes ComplicationData to shared UserDefaults via App Group.
enum ComplicationDataStore {
    private static let key = "ComplicationData"

    /// Derives the App Group suite name from the current bundle identifier.
    ///
    /// Bundle IDs follow the pattern: `org.nightscout.{TEAM}.trio[.watchkitapp[.TrioWatchComplication]]`
    /// App Group follows: `group.org.nightscout.{TEAM}.trio.trio-app-group`
    ///
    /// We take the first 4 segments of the bundle ID to construct the group name.
    static var suiteName: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 4 else { return nil }
        let baseID = parts[0 ... 3].joined(separator: ".")
        return "group.\(baseID).trio-app-group"
    }

    /// Save complication data to shared UserDefaults.
    static func save(_ data: ComplicationData) {
        guard let suiteName = suiteName,
              let defaults = UserDefaults(suiteName: suiteName)
        else { return }

        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: key)
        }
    }

    /// Load complication data from shared UserDefaults.
    static func load() -> ComplicationData? {
        guard let suiteName = suiteName,
              let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key)
        else { return nil }

        return try? JSONDecoder().decode(ComplicationData.self, from: data)
    }
}
