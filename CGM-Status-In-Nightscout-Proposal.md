# Feature Proposal: Include CGM Sensor Info in Nightscout Status Uploads

## Summary

This change adds CGM sensor metadata (sensor type, activation date, session start, transmitter ID) to the Nightscout device status payload that Trio already uploads. Currently, the status includes OpenAPS, pump, and uploader info but no CGM details. This small addition makes CGM data available to Nightscout and any downstream consumers (dashboards, monitoring tools, caregivers) without requiring a separate API or data source.

## Motivation

- **Caregiver visibility:** Parents and caregivers monitoring via Nightscout can see which CGM is active, when the sensor was started, and the transmitter ID — useful for knowing when a sensor session is nearing expiration.
- **Consistency:** Pump info (reservoir, battery) is already included in the status payload. CGM info is a natural complement.
- **Low risk:** The `cgm` field is optional (`NSCGMStatus?`), so existing Nightscout servers and clients that don't expect it are unaffected.

## Changes

### Files Modified

| File | Change |
|------|--------|
| `Trio/Sources/Models/NightscoutStatus.swift` | Added `NSCGMStatus` struct and optional `cgm` property |
| `Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift` | Added `fetchCGMStatus()` method and wired it into the status upload |

### 1. New Model: `NSCGMStatus` (NightscoutStatus.swift)

Added a new struct alongside the existing `NSPumpStatus`, `OpenAPSStatus`, etc.:

```swift
struct NSCGMStatus: JSON {
    let sensorType: String
    let sensorActivatedAt: Date?
    let sessionStartDate: Date?
    let transmitterID: String?
}
```

Added an optional property to `NightscoutStatus`:

```swift
struct NightscoutStatus: JSON {
    let device: String
    let openaps: OpenAPSStatus
    let pump: NSPumpStatus
    let uploader: Uploader
    let cgm: NSCGMStatus?       // <-- NEW
}
```

### 2. New Method: `fetchCGMStatus()` (NightscoutManager.swift)

Added 4 new imports to access CGM manager types:

```swift
import CGMBLEKit        // Dexcom G5/G6
import EversenseKit      // Eversense
import G7SensorKit       // Dexcom G7
import LibreTransmitter  // FreeStyle Libre
```

Added a private method on `BaseNightscoutManager` that resolves the active CGM manager via `FetchGlucoseManager` and extracts sensor info by type-checking against each supported CGM:

```swift
private func fetchCGMStatus() -> NSCGMStatus? {
    guard let fetchGlucose = TrioApp.resolver.resolve(FetchGlucoseManager.self),
          let cgm = fetchGlucose.cgmManager else { return nil }

    var sensorActivatedAt: Date?
    var sessionStartDate: Date?
    var transmitterID: String?
    var sensorType: String = "Unknown"

    if let manager = cgm as? LibreTransmitterManagerV3 {
        let info = manager.sensorInfoObservable
        sensorActivatedAt = info.activatedAt
        sessionStartDate = info.activatedAt
        transmitterID = info.sensorSerial
        sensorType = "FreeStyle Libre"
    } else if let manager = cgm as? G5CGMManager {
        let reading = manager.latestReading
        sensorActivatedAt = reading?.activationDate
        sessionStartDate = reading?.sessionStartDate
        transmitterID = reading?.transmitterID
        sensorType = "Dexcom G5"
    } else if let manager = cgm as? G6CGMManager {
        let reading = manager.latestReading
        sensorActivatedAt = reading?.activationDate
        sessionStartDate = reading?.sessionStartDate
        transmitterID = reading?.transmitterID
        sensorType = "Dexcom G6"
    } else if let manager = cgm as? G7CGMManager {
        sensorActivatedAt = manager.sensorActivatedAt
        sessionStartDate = manager.sensorActivatedAt
        transmitterID = manager.sensorName
        sensorType = "Dexcom G7"
    } else if let manager = cgm as? EversenseCGMManager {
        sensorActivatedAt = manager.state.activatedAt
        sessionStartDate = manager.state.activatedAt
        transmitterID = manager.state.bleNameString
        sensorType = "Eversense"
    }

    return NSCGMStatus(
        sensorType: sensorType,
        sensorActivatedAt: sensorActivatedAt,
        sessionStartDate: sessionStartDate,
        transmitterID: transmitterID
    )
}
```

### 3. Wiring Into Status Upload

In the existing status-building code (around line 605), the CGM status is fetched and included:

```swift
let cgmStatus = fetchCGMStatus()
let status = NightscoutStatus(
    device: NightscoutTreatment.local,
    openaps: openapsStatus,
    pump: pump,
    uploader: uploader,
    cgm: cgmStatus           // <-- NEW
)
```

## Supported CGM Types

| CGM | Manager Class | Fields Extracted |
|-----|--------------|-----------------|
| FreeStyle Libre | `LibreTransmitterManagerV3` | `sensorInfoObservable.activatedAt`, `.sensorSerial` |
| Dexcom G5 | `G5CGMManager` | `latestReading.activationDate`, `.sessionStartDate`, `.transmitterID` |
| Dexcom G6 | `G6CGMManager` | `latestReading.activationDate`, `.sessionStartDate`, `.transmitterID` |
| Dexcom G7 | `G7CGMManager` | `sensorActivatedAt`, `sensorName` |
| Eversense | `EversenseCGMManager` | `state.activatedAt`, `state.bleNameString` |

## Example Nightscout Payload (CGM section)

```json
{
  "cgm": {
    "sensorType": "Dexcom G7",
    "sensorActivatedAt": "2026-03-28T14:30:00Z",
    "sessionStartDate": "2026-03-28T14:30:00Z",
    "transmitterID": "DX4G7H"
  }
}
```

## Backward Compatibility

- The `cgm` field is **optional** (`NSCGMStatus?`). If no CGM is active or the type is unrecognized, it is `nil` and omitted from the JSON.
- Existing Nightscout servers will ignore the unknown `cgm` key — no breaking changes.
- The pattern mirrors how `PluginSource.readCGMResult()` already resolves sensor info for local display, so it uses well-established APIs on each CGM manager.

## Testing Notes

- Verified with Dexcom G7 — sensor type, activation date, and transmitter name appear correctly in the Nightscout status payload.
- Nil-safe for all fields; if a CGM is connected but a field isn't available, it gracefully returns `nil` for that property.
- No impact on upload frequency or payload size (adds ~100 bytes when present).
