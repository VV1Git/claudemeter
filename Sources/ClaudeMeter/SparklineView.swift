import Charts
import Foundation
import SwiftUI
import UsageCore

/// Utilization of one limit window over time, with the projection continued to the reset as
/// a dashed line and its confidence band as a faint cone.
///
/// The x-domain runs past `now` to `resetsAt` on purpose: the question the chart answers is
/// where the window is heading, not only where it has been. The 5-hour window is rolling, so
/// a declining line is a normal reading (usage ageing out) and is never smoothed or clipped
/// into a rise.
struct SparklineView: View {
    private let kind: WindowKind
    private let projection: Projection?
    private let now: Date
    private let severity: Severity?
    /// Filtered in `init` rather than in a computed property because the domains, the tint
    /// and the empty check all read it, and `body` runs on every poll.
    private let points: [Point]

    /// `severity` is defaulted so the contracted `init(samples:kind:projection:now:)` still
    /// applies; pass it whenever the caller has the snapshot's own classification, because the
    /// API sends a `severity` that need not agree with the numeric thresholds and the meter
    /// above this chart is coloured from that field.
    init(
        samples: [Sample], kind: WindowKind, projection: Projection?, now: Date,
        severity: Severity? = nil
    ) {
        self.kind = kind
        self.projection = projection
        self.now = now
        self.severity = severity
        self.points = Self.series(samples, kind: kind, now: now)
    }

    /// The trailing `kind.nominalDuration` of samples, ascending, cut at the most recent reset.
    ///
    /// `ProjectionEngine.usableSamples` is not reused — its 45-minute trailing window is far
    /// shorter than a chart wants — but its reset rule is, so a window that reset an hour ago
    /// does not leave the previous window's plateau on the chart joined to the current one by a
    /// cliff that never happened.
    private static func series(_ samples: [Sample], kind: WindowKind, now: Date) -> [Point] {
        let windowStart = now.addingTimeInterval(-kind.nominalDuration)
        let ordered = samples
            .filter { $0.t >= windowStart && $0.t <= now && $0.percent(for: kind) != nil }
            .sorted { $0.t < $1.t }

        var start = 0
        if ordered.count > 1 {
            for index in 1..<ordered.count
            where isReset(ordered[index - 1], ordered[index], kind: kind) {
                start = index
            }
        }

        return ordered[start...].enumerated().map {
            Point(id: $0.offset, t: $0.element.t, percent: $0.element.percent(for: kind) ?? 0)
        }
    }

    /// A reset, not a decline. The 5-hour window is rolling, so utilization falling as usage
    /// ages out is ordinary and stays on the chart; only a cliff of at least
    /// `ProjectionEngine.resetDropThreshold` points between consecutive polls starts a new
    /// series. The threshold is `UsageCore`'s and is not restated here.
    private static func isReset(_ previous: Sample, _ next: Sample, kind: WindowKind) -> Bool {
        guard let before = previous.percent(for: kind), let after = next.percent(for: kind) else {
            return false
        }
        return before - after >= ProjectionEngine.resetDropThreshold
    }

    private struct Point: Identifiable {
        let id: Int
        let t: Date
        let percent: Double
    }

    private struct BandPoint: Identifiable {
        let id: Int
        let t: Date
        let low: Double
        let high: Double
    }

    private static let height: CGFloat = 64
    /// Minimum horizontal context, so two polls a minute apart don't render as a chart
    /// spanning one minute.
    private static let minimumSpan: TimeInterval = 15 * 60

    var body: some View {
        Group {
            if points.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        .frame(height: Self.height)
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(band) { point in
                AreaMark(
                    x: .value("Time", point.t),
                    yStart: .value("Low", point.low),
                    yEnd: .value("High", point.high)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(tint.opacity(0.10))
            }

            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", point.percent),
                    series: .value("Series", "observed")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(areaGradient)
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", point.percent),
                    series: .value("Series", "observed")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .foregroundStyle(tint)
            }

            if points.count == 1, let only = points.first {
                PointMark(x: .value("Time", only.t), y: .value("Usage", only.percent))
                    .symbolSize(14)
                    .foregroundStyle(tint)
            }

            ForEach(projected) { point in
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", point.percent),
                    series: .value("Series", "projected")
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 3]))
                .foregroundStyle(tint.opacity(0.55))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: xStart...xEnd)
        .chartYScale(domain: 0...yUpper)
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xLabel(date))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            Text("No history yet — a point is recorded each poll.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Series

    /// Anchored at the snapshot's own `currentPercent` rather than at the last sample: the
    /// snapshot is the authority for "now", and the two can differ by a poll.
    private var projected: [Point] {
        guard let projection,
            let resetsAt = projection.resetsAt, resetsAt > now,
            let projectedAtReset = projection.projectedAtReset
        else { return [] }
        return [
            Point(id: 0, t: now, percent: projection.currentPercent),
            Point(id: 1, t: resetsAt, percent: projectedAtReset),
        ]
    }

    private var band: [BandPoint] {
        guard let projection,
            let resetsAt = projection.resetsAt, resetsAt > now,
            let projectedAtReset = projection.projectedAtReset,
            let halfWidth = projection.projectedBand, halfWidth > 0
        else { return [] }
        let current = projection.currentPercent
        return [
            BandPoint(id: 0, t: now, low: current, high: current),
            BandPoint(
                id: 1, t: resetsAt,
                low: max(0, projectedAtReset - halfWidth),
                high: min(yUpper, projectedAtReset + halfWidth)),
        ]
    }

    // MARK: Scales

    private var xStart: Date {
        let fallback = now.addingTimeInterval(-min(kind.nominalDuration, Self.minimumSpan))
        guard let earliest = points.first?.t else { return fallback }
        return min(earliest, fallback)
    }

    private var xEnd: Date {
        let latest = max(now, points.last?.t ?? now)
        let end = projected.last?.t ?? latest
        return max(end, xStart.addingTimeInterval(Self.minimumSpan))
    }

    /// 100 unless the series or the projection goes over it — the cap is the reference the
    /// chart is read against, so it never scales away, and an over-100 projection is not
    /// flattened into the ceiling.
    private var yUpper: Double {
        var highest = points.map(\.percent).max() ?? 0
        if let projection, let projectedAtReset = projection.projectedAtReset {
            highest = max(highest, projectedAtReset + (projection.projectedBand ?? 0))
        }
        let rounded = (max(highest, 100) / 10).rounded(.up) * 10
        return min(200, rounded)
    }

    private var yTicks: [Double] {
        yUpper > 100 ? [0, 100, yUpper] : [0, 50, 100]
    }

    // MARK: Labels

    private func xLabel(_ date: Date) -> String {
        kind == .fiveHour
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The caller's severity when it has one — that is `UsageSnapshot.severity(for:)`, which
    /// prefers the API's own classification — falling back to the same `UsageCore` numeric
    /// classifier the snapshot itself falls back to. No threshold is restated here.
    private var tint: Color {
        SeverityStyle.color(severity ?? Severity.fromPercent(currentPercent))
    }

    private var currentPercent: Double {
        projection?.currentPercent ?? points.last?.percent ?? 0
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [tint.opacity(0.28), tint.opacity(0.03)],
            startPoint: .top, endPoint: .bottom)
    }

    private var accessibilitySummary: String {
        var summary = "\(kind.longLabel) usage, \(Self.spoken(currentPercent)) percent now"
        if let projectedAtReset = projection?.projectedAtReset {
            summary += ", projected \(Self.spoken(projectedAtReset)) percent at reset"
        }
        return summary
    }

    /// Clamped before the `Int` conversion. `utilization` is decoded straight out of JSON this
    /// app does not own and is neither range-checked nor bounded by `LimitsClient`, and
    /// `Int(_:)` traps on a `Double` too large to represent — a corrupt payload has to read as a
    /// silly number, never crash the panel. Same guard as `MenuBarLabelText.percentCeiling`.
    private static func spoken(_ percent: Double) -> String {
        guard percent.isFinite else { return "an unknown" }
        return "\(Int(min(max(percent, 0), 9_999).rounded()))"
    }
}
