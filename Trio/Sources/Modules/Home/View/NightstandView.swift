import Charts
import SwiftUI
import UIKit

/// Bedside display shown while the phone lies on its side on the Home tab.
///
/// Trio's iPhone UI is portrait-only, so the content is drawn rotated to match the
/// physical orientation instead of unlocking rotation for every screen.
/// Tapping steps the brightness down; the screen stays awake while it's shown.
struct NightstandView: View {
    let rotation: Angle
    let units: GlucoseUnits
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let glucose: [GlucoseStored] // last two readings, oldest first
    let eventualGlucose: Decimal?
    let history: [GlucoseStored]
    /// Trio's forecast cone in mg/dL, one value every 5 minutes from `forecastStart`.
    let minForecast: [Int]
    let maxForecast: [Int]
    let forecastStart: Date?

    /// Index into `Self.levels`, kept between nights.
    @AppStorage("nightstandBrightnessLevel") private var level = 0
    @State private var originalBrightness: CGFloat?

    /// Screen backlight and content opacity per level, brightest first.
    private static let levels: [(screen: CGFloat, content: Double)] = [
        (0.6, 1.0),
        (0.3, 0.85),
        (0.1, 0.6),
        (0.0, 0.35),
        (0.0, 0.12)
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.everyMinute) { context in
                content(now: context.date)
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(rotation)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .opacity(currentLevel.content)
        .background(Color.black)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dimStep() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            originalBrightness = screen?.brightness
            applyBrightness()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let originalBrightness { screen?.brightness = originalBrightness }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Tap to change brightness"))
        .accessibilityAction { dimStep() }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(alignment: .center, spacing: 12) {
                Text(glucoseText)
                    .font(.system(size: 190, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if isReadingFresh, let arrow = trendArrow {
                    Image(systemName: arrow)
                        .font(.system(size: 90, weight: .bold))
                        .foregroundStyle(glucoseColor)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(now, style: .time)
                    .font(.system(size: 72, weight: .light, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                HStack(spacing: 16) {
                    Text(detailText(now: now))
                    if let eventualGlucose {
                        Label {
                            Text(eventualGlucose.formatted(for: units))
                        } icon: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .accessibilityLabel(Text("Eventual glucose \(eventualGlucose.formatted(for: units))"))
                    }
                }
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                trendChart(now: now)
                    .frame(height: 110)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 320)
        }
        // Clear the Dynamic Island, which sits on the left or right edge depending on the way the phone is turned
        .padding(.horizontal, 72)
    }

    // MARK: - Trend chart

    /// Last 6 hours of readings and the next 2 hours of Trio's forecast cone, plotted in mg/dL.
    @ViewBuilder private func trendChart(now: Date) -> some View {
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now.addingTimeInterval(2 * 3600)
        let readings = history.compactMap { reading -> (date: Date, value: Int)? in
            guard let date = reading.date, date >= start else { return nil }
            return (date, Int(reading.glucose))
        }
        let cone = forecastCone(until: end)
        let highest = max(readings.map(\.value).max() ?? 0, cone.map(\.high).max() ?? 0, Int(truncating: highGlucose as NSNumber))
        let low = Double(truncating: lowGlucose as NSNumber)
        let high = Double(truncating: highGlucose as NSNumber)

        Chart {
            ForEach(cone, id: \.date) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Low", point.low),
                    yEnd: .value("High", point.high)
                )
                .foregroundStyle(Color.blue.opacity(0.35))
            }
            RuleMark(y: .value("Low", low))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.red.opacity(0.6))
            RuleMark(y: .value("High", high))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.orange.opacity(0.6))
            RuleMark(x: .value("Now", now))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.white.opacity(0.25))
            ForEach(readings, id: \.date) { reading in
                PointMark(
                    x: .value("Time", reading.date),
                    y: .value("Glucose", reading.value)
                )
                .symbolSize(10)
                .foregroundStyle(pointColor(for: reading.value))
            }
        }
        .chartXScale(domain: start ... end)
        .chartYScale(domain: 40 ... max(250, highest + 10))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    private func forecastCone(until end: Date) -> [(date: Date, low: Int, high: Int)] {
        guard let forecastStart else { return [] }
        return zip(minForecast, maxForecast).enumerated().compactMap { index, bounds in
            let date = forecastStart.addingTimeInterval(TimeInterval(index * 300))
            guard date <= end else { return nil }
            return (date, min(bounds.0, bounds.1), max(bounds.0, bounds.1))
        }
    }

    private func pointColor(for value: Int) -> Color {
        let glucose = Decimal(value)
        if glucose <= lowGlucose { return .red }
        if glucose >= highGlucose { return .orange }
        return Color.white.opacity(0.8)
    }

    // MARK: - Glucose

    /// Same freshness rule as the home screen bobble.
    private var isReadingFresh: Bool {
        guard let date = glucose.last?.date else { return false }
        return Date().timeIntervalSince(date) < 12 * 60
    }

    private var glucoseText: String {
        guard isReadingFresh, let value = glucose.last?.glucose else { return "– –" }
        return value == 400 ? "HIGH" : Decimal(value).formatted(for: units)
    }

    private func detailText(now _: Date) -> String {
        guard isReadingFresh else {
            return String(localized: "No recent reading", comment: "Nightstand: no glucose in the last 12 minutes")
        }
        let ago = TimeAgoFormatter.minutesAgo(from: glucose.last?.date)
        guard glucose.count >= 2, let last = glucose.last?.glucose, let previous = glucose.first?.glucose else {
            return ago
        }
        return ago + "  " + (Decimal(last) - Decimal(previous)).formattedDelta(for: units)
    }

    private var trendArrow: String? {
        switch glucose.last?.directionEnum {
        case .doubleUp,
             .tripleUp: return "arrow.up.to.line"
        case .singleUp: return "arrow.up"
        case .fortyFiveUp: return "arrow.up.right"
        case .flat: return "arrow.right"
        case .fortyFiveDown: return "arrow.down.right"
        case .singleDown: return "arrow.down"
        case .doubleDown,
             .tripleDown: return "arrow.down.to.line"
        default: return nil
        }
    }

    /// Matches `CurrentGlucoseView`: in range uses the primary color, outside it the range colors.
    private var glucoseColor: Color {
        guard isReadingFresh, let value = glucose.last?.glucose else { return .secondary }
        let glucose = Decimal(value)
        guard glucose <= lowGlucose || glucose >= highGlucose else { return .primary }
        let isDynamic = glucoseColorScheme == .dynamicColor
        return Trio.getDynamicGlucoseColor(
            glucoseValue: glucose,
            highGlucoseColorValue: isDynamic ? 220 : highGlucose,
            lowGlucoseColorValue: isDynamic ? 55 : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    // MARK: - Brightness

    private var currentLevel: (screen: CGFloat, content: Double) {
        Self.levels[min(max(level, 0), Self.levels.count - 1)]
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func dimStep() {
        level = (level + 1) % Self.levels.count
        applyBrightness()
    }

    private func applyBrightness() {
        screen?.brightness = currentLevel.screen
    }
}
