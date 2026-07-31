import Charts
import Foundation
import SwiftUI
import UsageCore

/// Utilization of one limit window over its own period, with the projection continued to the
/// reset as a dashed line and its confidence band as a faint cone.
///
/// The x-domain is the period itself — `[resetsAt - nominalDuration, resetsAt]` — not a
/// trailing window ending at `now`. The chart answers "where is this window heading before it
/// resets", and a lookback cannot: anchored on `now` it slid forward every poll, reached back
/// across turnovers into the previous block, and on 30 July spanned 6.93 hours under a heading
/// that read "Last 5 hours". A fixed domain also means the left edge holds still between polls
/// while the line grows into it, instead of the whole plot creeping leftward under the reader.
struct SparklineView: View {
    private let kind: WindowKind
    private let projection: Projection?
    private let now: Date
    private let severity: Severity?
    /// Resolved in `init` rather than in computed properties because the marks, the scales, the
    /// tint and the empty check all read them, and `body` runs on every poll.
    private let points: [Point]
    private let xStart: Date
    private let xEnd: Date
    /// Whether this window has any reading at all, as against none inside the current period.
    /// A fixed domain empties the chart at every turnover until the next poll lands — eight
    /// minutes on 30 July, up to five under backoff, four or five times a day — and "no history
    /// yet" would read as data loss where the truth is that the period just opened.
    private let hasAnySamples: Bool

    /// `resetsAt` is its own parameter rather than read off `projection` because `PanelView`
    /// nils the projection during an outage while the cached snapshot still knows the period.
    /// The x-axis must not change shape merely because a forecast was suppressed.
    ///
    /// `severity` is defaulted so the contracted `init(samples:kind:resetsAt:projection:now:)`
    /// still applies; pass it whenever the caller has the snapshot's own classification,
    /// because the API sends a `severity` that need not agree with the numeric thresholds and
    /// the meter above this chart is coloured from that field.
    init(
        samples: [Sample], kind: WindowKind, resetsAt: Date?, projection: Projection?, now: Date,
        severity: Severity? = nil
    ) {
        self.kind = kind
        self.projection = projection
        self.now = now
        self.severity = severity

        let period = kind.chartPeriod(resetsAt: resetsAt ?? projection?.resetsAt, now: now)
        self.xStart = period.start
        self.xEnd = period.end
        self.points = ProjectionEngine.chartSamples(samples, kind: kind, period: period)
            .enumerated()
            .map { Point(id: $0.offset, t: $0.element.t, percent: $0.element.percent(for: kind) ?? 0) }
        self.hasAnySamples = samples.contains { $0.percent(for: kind) != nil }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if points.isEmpty {
                    placeholder
                } else {
                    chart
                }
            }
            .frame(height: Self.height)

            if let coverageNote {
                Text(coverageNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            // Behind everything: the stretch of the period this app was not watching.
            if let gap = unrecordedGap {
                RectangleMark(
                    xStart: .value("From", gap.lowerBound),
                    xEnd: .value("To", gap.upperBound),
                    yStart: .value("Floor", 0),
                    yEnd: .value("Ceiling", yUpper)
                )
                .foregroundStyle(Color.primary.opacity(0.05))
            }

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

            // Where measurement stops and forecast begins. On a trailing domain this was the
            // right-hand edge and needed no mark; on the period the observed line is the
            // shorter segment — 14.6% of the width against the forecast's 31.9% on the live
            // weekly chart — and the dash pattern alone stops carrying the boundary.
            if now >= xStart, now <= xEnd {
                RuleMark(x: .value("Now", now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 2]))
                    .foregroundStyle(Color.primary.opacity(0.14))
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
            // One tick a day across the weekly window, rather than the three the automatic
            // count chose for a seven-day domain — three weekday names across a week reads as
            // a sample of the axis rather than as the axis. The 5-hour window keeps automatic
            // ticks, held to four so the rightmost label is not clipped by the plot edge.
            AxisMarks(values: xAxisDates) { value in
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
            Text(
                hasAnySamples
                    ? "This window has no readings yet — it just opened."
                    : "No history yet — a point is recorded each poll.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Series

    /// Anchored at the snapshot's own `currentPercent` rather than at the last sample: the
    /// snapshot is the authority for "now", and the two can differ by a poll.
    /// Every value is `isFinite`-checked before it reaches a mark. `MeterRow` and
    /// `MenuBarLabelText` both guard their own conversions, but Swift Charts is handed these
    /// doubles raw, and `min`/`max` return NaN unchanged rather than clamping it away.
    private var projected: [Point] {
        guard let projection,
            let resetsAt = projection.resetsAt, resetsAt > now,
            let projectedAtReset = projection.projectedAtReset, projectedAtReset.isFinite,
            projection.currentPercent.isFinite
        else { return [] }
        return [
            Point(id: 0, t: now, percent: projection.currentPercent),
            Point(id: 1, t: resetsAt, percent: projectedAtReset),
        ]
    }

    /// The cone's endpoints come from `Projection` rather than from arithmetic here, so the
    /// shaded area and the text row cannot disagree about the same interval. On the live weekly
    /// reading that changes what the cone means: its lower edge used to descend from 35% toward
    /// the baseline, drawing a fixed window losing usage it cannot lose, and now runs flat at
    /// the current reading, which is the floor a fixed window actually has.
    private var band: [BandPoint] {
        guard let projection,
            let resetsAt = projection.resetsAt, resetsAt > now,
            projection.currentPercent.isFinite,
            let low = projection.projectedLow, let high = projection.projectedHigh,
            high - low > 0
        else { return [] }
        let current = projection.currentPercent
        return [
            BandPoint(id: 0, t: now, low: current, high: current),
            BandPoint(id: 1, t: resetsAt, low: low, high: high),
        ]
    }

    // MARK: Scales

    /// 100 unless the series or the projection goes over it — the cap is the reference the
    /// chart is read against, so it never scales away, and an over-100 projection is not
    /// flattened into the ceiling.
    ///
    /// Grown for the projection's centre but deliberately *not* for the top of its interval.
    /// Rescaling to fit the band is actively harmful now that the band is no longer withdrawn:
    /// this account's weekly interval reaches 103%, which would push the ceiling to 110 and
    /// squash the readings, and a one-hour-old week's interval would push it to the 200 cap and
    /// leave a 3% line in the bottom sliver of the plot. A cone that runs off the top reads as
    /// "this could go over" faster than a rescaled axis does, and Swift Charts clips marks
    /// outside the domain, so nothing absurd reaches the renderer.
    private var yUpper: Double {
        var highest = points.map(\.percent).max() ?? 0
        if let projection, let projectedAtReset = projection.projectedAtReset,
            projectedAtReset.isFinite
        {
            highest = max(highest, projectedAtReset)
        }
        guard highest.isFinite else { return 100 }
        let rounded = (max(highest, 100) / 10).rounded(.up) * 10
        return min(200, rounded)
    }

    private var yTicks: [Double] {
        yUpper > 100 ? [0, 100, yUpper] : [0, 50, 100]
    }

    // MARK: Coverage

    /// The stretch of the period before the first recorded reading, when there is enough of it
    /// to be worth saying so.
    ///
    /// Blank space under a chart whose y-axis starts at zero reads as *zero usage*, and that is
    /// a lie the fixed domain newly makes possible: the weekly window is seven days wide while
    /// this app has a day of samples, and the first of them already read 13%. The unwatched
    /// stretch is therefore shaded and named rather than left to be misread as a quiet start.
    ///
    /// The 8% floor keeps it off the 5-hour chart in ordinary running, where the first poll
    /// after a turnover lands a few minutes in.
    private var unrecordedGap: ClosedRange<Date>? {
        guard let first = points.first?.t, first > xStart else { return nil }
        let span = xEnd.timeIntervalSince(xStart)
        guard span > 0, first.timeIntervalSince(xStart) / span >= 0.08 else { return nil }
        return xStart...first
    }

    /// What turns the shaded block from ambiguous into unambiguous: the region is unwatched,
    /// not idle, and the window was already part-used when watching began.
    private var coverageNote: String? {
        guard unrecordedGap != nil, let first = points.first else { return nil }
        let when = first.t.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "No readings before \(when) · \(Self.spoken(first.percent))% by then"
    }

    // MARK: Labels

    /// Tick instants, stated rather than left to `.automatic`.
    ///
    /// Two reasons the automatic values do not survive a fixed domain. They chose three ticks
    /// for a seven-day span, which reads as a sample of the axis rather than as the axis; and
    /// they place a tick within a few percent of the domain end, where Charts centres the label
    /// on the tick, finds it crossing the plot edge, and renders `6 PM` as `6…` — then, given
    /// trailing padding to work in, as a bare `…`. Padding cannot fix it because the label slot
    /// is reserved symmetrically about the tick. Not emitting a tick there does.
    ///
    /// One an hour for the 5-hour window, one a day for the weekly one, each dropped if it
    /// falls inside `edgeMargin` of either end.
    private var xAxisDates: [Date] {
        let span = xEnd.timeIntervalSince(xStart)
        guard span > 0, span.isFinite else { return [] }
        let step: TimeInterval = kind == .fiveHour ? 3600 : 24 * 3600
        let margin = span * Self.edgeMargin

        // Anchored on the period's own start rather than on clock boundaries: the 5-hour window
        // opens at :20 past on this account, so hour-aligned ticks would drift relative to the
        // period while these stay fixed to it.
        var dates: [Date] = []
        var offset = step
        while offset < span {
            dates.append(xStart.addingTimeInterval(offset))
            offset += step
        }
        return dates.filter {
            $0.timeIntervalSince(xStart) >= margin && xEnd.timeIntervalSince($0) >= margin
        }
    }

    /// How close to the plot edge a tick may sit before its label is the thing that gets cut.
    private static let edgeMargin: Double = 0.07

    /// Minutes are kept on the 5-hour axis because the ticks are anchored to the period, which
    /// opens whenever the block did — :20 past on this account — so an hour-only label would
    /// put "5 PM" under a tick standing at 5:20.
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
        var summary = "\(kind.longLabel) window, \(Self.spoken(currentPercent)) percent now"
        if let projectedAtReset = projection?.projectedAtReset {
            summary += ", projected \(Self.spoken(projectedAtReset)) percent at reset"
            // The interval is read out too. A forecast this wide is the reason the row exists;
            // announcing only the centre would give a screen reader the one number the sighted
            // reading is explicitly designed not to be taken alone.
            if let low = projection?.projectedLow, let high = projection?.projectedHigh,
                high - low > 0
            {
                let top = high >= 100 ? "over 100" : Self.spoken(high)
                summary += ", between \(Self.spoken(low)) and \(top) percent"
            }
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
