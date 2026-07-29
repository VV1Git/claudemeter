import SwiftUI
import UsageCore

// MARK: - Meter row

/// One limit window: title, percentage, capsule meter, reset line, projection line.
///
/// Both the reset and the projection lines are optional and are omitted rather than shown empty —
/// a row that says `resets —` or `↗ 0 pts/hr` reads as broken, and the percentage plus the bar
/// already stand on their own.
struct MeterRow: View {
    private let title: String
    private let percent: Double?
    private let severity: Severity
    private let resetsAt: Date?
    private let projection: Projection?
    private let now: Date

    init(
        title: String, percent: Double?, severity: Severity,
        resetsAt: Date?, projection: Projection?, now: Date
    ) {
        self.title = title
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.projection = projection
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.body)
                Spacer(minLength: 8)
                Text(percentText)
                    .font(.body)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(percentColor)
            }

            bar

            if let resetText {
                Text(resetText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let paceText {
                HStack(spacing: 5) {
                    Text(paceText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if isEstimated {
                        EstimatedBadge()
                    }
                }
            }

            if let capText {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                    Text(capText)
                        .monospacedDigit()
                    // The badge belongs to whichever projected line is on screen. The cap
                    // warning is as much a forecast as the pace clause, and when the pace
                    // clause is suppressed this is the only line an estimate can be read from.
                    if isEstimated, paceText == nil {
                        EstimatedBadge()
                    }
                }
                .font(.caption)
                .foregroundStyle(SeverityStyle.color(.critical))
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Meter

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(SeverityStyle.track)
                Capsule(style: .continuous)
                    .fill(SeverityStyle.color(severity))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: SeverityStyle.barHeight)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard let percent, percent.isFinite else { return 0 }
        return min(max(percent / 100, 0), 1)
    }

    // MARK: Text

    /// `Int(_:)` traps on any `Double` past `Int.max`, and `utilization` reaches this view
    /// straight out of JSON the app does not own — `LimitsClient` decodes it unclamped — so every
    /// conversion below goes through `integer(_:)`. The ceiling is the one `MenuBarLabelText`
    /// uses, so a nonsense payload produces the same nonsense number in the menu bar and here
    /// instead of killing the app in one of the two.
    private static let integerCeiling: Double = 9_999

    private static func integer(_ value: Double) -> Int {
        Int(min(max(value, -integerCeiling), integerCeiling).rounded())
    }

    /// Negatives clamp to zero to match the menu bar: utilization is a share of a limit, and
    /// `-3%` is not a reading a user can act on.
    private var percentText: String {
        guard let percent, percent.isFinite else { return "—" }
        return "\(Self.integer(max(percent, 0)))%"
    }

    /// Normal severity stays plain: colouring every healthy number accent-blue makes the two
    /// rows shout, and the bar already carries the state.
    private var percentColor: Color {
        guard percent != nil else { return Color.secondary }
        return severity == .normal ? Color.primary : SeverityStyle.color(severity)
    }

    /// A countdown while the reset is close, a weekday and time once it is far enough out that
    /// "in 4d 6h" stops being useful.
    private var resetText: String? {
        // A non-finite instant — the sample cache stores dates as raw epoch seconds — has no
        // weekday to format, so it is dropped rather than handed to a date formatter.
        guard let resetsAt, resetsAt.timeIntervalSince1970.isFinite else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 60 { return "resets now" }
        if remaining < 12 * 3600 {
            return "resets in " + MenuBarLabelText.compactDuration(until: resetsAt, now: now)
        }
        return "resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// `↗ 12 pts/hr · 63% at reset ± 4`, with either clause dropped when it says nothing, and
    /// the whole line dropped when both do.
    private var paceText: String? {
        let clauses = [rateClause, atResetClause].compactMap { $0 }
        return clauses.isEmpty ? nil : clauses.joined(separator: " · ")
    }

    private var isEstimated: Bool { projection?.basis == .estimated }

    /// Suppressed below half a point per hour: the API reports utilization coarsely, so a rate
    /// that small is fit noise rather than a trend.
    private var rateClause: String? {
        guard let projection else { return nil }
        let rate = projection.percentPerHour
        guard rate.isFinite, abs(rate) >= 0.5 else { return nil }
        let magnitude = abs(rate)
        // One decimal below 10 points/hour: at the low end the difference between 0.6 and 1.4
        // points an hour is the difference between coasting and capping before the reset.
        let value = magnitude < 10
            ? String(format: "%.1f", magnitude)
            : "\(Self.integer(magnitude))"
        return "\(rate > 0 ? "↗" : "↘") \(value) pts/hr"
    }

    /// Dropped when the projection lands within a point of where the window already is — a flat
    /// pace restating the current number is noise.
    private var atResetClause: String? {
        guard let projection, let projected = projection.projectedAtReset, projected.isFinite,
            abs(projected - projection.currentPercent) >= 1
        else { return nil }
        var clause = "\(Self.integer(projected))% at reset"
        if let band = projection.projectedBand, band.isFinite, band.rounded() >= 1 {
            clause += " ± \(Self.integer(band))"
        }
        return clause
    }

    /// `compactDuration` answers `now` for anything under a minute — and for a cap time that has
    /// already passed — so the interval is checked here first: `hits 100% in now` reads as a
    /// half-built string rather than as a warning.
    private var capText: String? {
        guard let projection, projection.willCapEarly, let cap = projection.timeToCap,
            cap.timeIntervalSince1970.isFinite
        else { return nil }
        guard cap.timeIntervalSince(now) >= 60 else { return "hits 100% now" }
        return "hits 100% in " + MenuBarLabelText.compactDuration(until: cap, now: now)
    }
}

// MARK: - Estimated badge

extension MeterRow {
    /// Marks a projection fitted from transcript velocity rather than from the poll series.
    fileprivate struct EstimatedBadge: View {
        var body: some View {
            Text("estimated")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
    }
}
