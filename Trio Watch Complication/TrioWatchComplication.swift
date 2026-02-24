import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let glucose: String
    let glucoseColorHex: String
    let trend: String?
    let delta: String?
    let iob: String?
    let cob: String?
    let lastLoopTime: String?
    let isStale: Bool

    /// Converts the raw direction name (e.g. "SingleUp") to a Unicode arrow symbol (e.g. "↑")
    var trendArrow: String? {
        guard let trend = trend else { return nil }
        switch trend {
        case "DoubleUp": return "↑↑"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "↓↓"
        default: return trend
        }
    }

    static var placeholder: TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            glucose: "---",
            glucoseColorHex: "#ffffff",
            trend: nil,
            delta: nil,
            iob: nil,
            cob: nil,
            lastLoopTime: nil,
            isStale: false
        )
    }
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        .placeholder
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh every 5 minutes to match CGM reading frequency
        let refreshDate = Date().addingTimeInterval(5 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    private func currentEntry() -> TrioWatchComplicationEntry {
        guard let data = ComplicationDataStore.load() else {
            return .placeholder
        }

        return TrioWatchComplicationEntry(
            date: data.updatedAt,
            glucose: data.glucose,
            glucoseColorHex: data.glucoseColorHex,
            trend: data.trend,
            delta: data.delta,
            iob: data.iob,
            cob: data.cob,
            lastLoopTime: data.lastLoopTime,
            isStale: data.isStale
        )
    }
}

// MARK: - Entry View Router

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryRectangular:
            TrioRectangularView(entry: entry)
        case .accessoryCircular:
            TrioCircularView(entry: entry)
        case .accessoryCorner:
            TrioCornerView(entry: entry)
        case .accessoryInline:
            TrioInlineView(entry: entry)
        default:
            TrioCircularView(entry: entry)
        }
    }
}

// MARK: - Rectangular Complication (Large Readout)

struct TrioRectangularView: View {
    var entry: TrioWatchComplicationEntry

    private var glucoseColor: Color {
        entry.isStale ? .secondary : Color(hex: entry.glucoseColorHex)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.isStale ? "--" : entry.glucose)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(glucoseColor)
                .widgetAccentable()

            if let trend = entry.trendArrow, !entry.isStale {
                Text(trend)
                    .font(.title2)
                    .foregroundStyle(glucoseColor)
            }

            if let delta = entry.delta, !entry.isStale {
                Text(delta)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Circular Complication (Glucose + Trend)

struct TrioCircularView: View {
    var entry: TrioWatchComplicationEntry

    private var glucoseColor: Color {
        entry.isStale ? .secondary : Color(hex: entry.glucoseColorHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(entry.isStale ? "--" : entry.glucose)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(glucoseColor)
                .widgetAccentable()
                .minimumScaleFactor(0.6)

            if let trend = entry.trendArrow, !entry.isStale {
                Text(trend)
                    .font(.caption)
                    .foregroundStyle(glucoseColor)
            }
        }
        .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Corner Complication (Glucose in Curve)

struct TrioCornerView: View {
    var entry: TrioWatchComplicationEntry

    private var glucoseColor: Color {
        entry.isStale ? .secondary : Color(hex: entry.glucoseColorHex)
    }

    var body: some View {
        Text(entry.isStale ? "--" : entry.glucose)
            .font(.system(.title3, design: .rounded))
            .fontWeight(.bold)
            .foregroundStyle(glucoseColor)
            .widgetCurvesContent()
            .widgetLabel {
                if let trend = entry.trendArrow, let delta = entry.delta, !entry.isStale {
                    Text("\(trend) \(delta)")
                } else {
                    Text("Trio")
                }
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Inline Complication (Single Line)

struct TrioInlineView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        if entry.isStale {
            Text("Trio --")
        } else {
            let trend = entry.trendArrow ?? ""
            let delta = entry.delta ?? ""
            Text("\(entry.glucose) \(trend) \(delta)")
        }
    }
}

// MARK: - Widget Configuration

@main struct TrioWatchComplication: Widget {
    let kind: String = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio Glucose")
        .description("Live glucose readout for your watch face")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline
        ])
    }
}

// MARK: - Helpers

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}

extension Color {
    /// Initialize a Color from a hex string (e.g. "#ff0000" or "ff0000")
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
