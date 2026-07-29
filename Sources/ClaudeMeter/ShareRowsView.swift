import Foundation
import SwiftUI

// MARK: - Share rows

/// One proportion row of a split: a label, the bar, and the percentage.
///
/// `detail` carries the absolute figure the share was computed from (a token count, a
/// message count) so a bar never has to be read as a quantity. `PanelView` builds these
/// from `ModelUsage` / `EffortUsage`, which keeps this view independent of the aggregate
/// types and reusable for any split.
struct ShareRow: Identifiable {
    let id: String
    let label: String
    let detail: String
    /// 0…1. Values outside that range are clamped when drawn rather than rejected, so a
    /// caller dividing by a total that excludes some bucket cannot overflow the bar. A
    /// non-finite value — `0 / 0` from an empty bucket — reads as zero, not as a full bar.
    let fraction: Double

    init(id: String, label: String, detail: String, fraction: Double) {
        self.id = id
        self.label = label
        self.detail = detail
        self.fraction = fraction
    }
}

/// The model and effort splits: compact proportion rows, one accent-tinted bar each.
///
/// Deliberately not a pie and deliberately not multi-hued — the rows are one series read
/// against a shared baseline, so identity comes from the label, never from colour.
struct ShareRowsView: View {
    private let rows: [ShareRow]

    init(rows: [ShareRow]) {
        self.rows = rows
    }

    var body: some View {
        if rows.isEmpty {
            Text("Nothing recorded yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.label)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(row.detail)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            ShareBar(fraction: row.fraction)
                            Text(UsageNumberFormat.share(row.fraction))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        Text("\(row.label), \(UsageNumberFormat.share(row.fraction)), \(row.detail)")
                    )
                }
            }
        }
    }
}

// MARK: - Bar

/// Same geometry as the window meters — the track and the height come from `SeverityStyle` so
/// there is one definition of a meter in the app — but tinted accent rather than by severity,
/// because a share is not a limit.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SeverityStyle.track)
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: UsageNumberFormat.clampedShare(fraction) * proxy.size.width)
            }
        }
        .frame(height: SeverityStyle.barHeight)
    }
}

// MARK: - Number formatting

/// Formatting shared by the chart and list views. Lives in the view layer because `UsageCore`
/// exposes raw counts and dollars — its one formatter, `MenuBarLabelText`, renders the menu bar
/// string and a countdown to a future date, neither of which is any of these. Every figure here
/// is approximate by construction: token totals are abbreviated and costs are equivalents at
/// published API rates, marked with `~`.
enum UsageNumberFormat {
    /// `842`, `12.4K`, `1.4M`, `2B` — abbreviated so a 30-day total fits an axis label.
    static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        switch value {
        case ..<1_000: return "\(max(0, count))"
        case ..<1_000_000: return abbreviated(value / 1_000, "K")
        case ..<1_000_000_000: return abbreviated(value / 1_000_000, "M")
        default: return abbreviated(value / 1_000_000_000, "B")
        }
    }

    /// One decimal below 100 so `12.4K` keeps the digit that distinguishes it from `12.9K`, and
    /// no trailing `.0`, so a round two billion reads `2B`.
    private static func abbreviated(_ value: Double, _ suffix: String) -> String {
        guard value < 100 else { return String(format: "%.0f%@", value, suffix) }
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    /// Cost equivalent, always tilde-prefixed: these are list-price equivalents for
    /// subscription usage that was never billed per token.
    static func cost(_ dollars: Double) -> String {
        let value = max(0, dollars)
        if value == 0 { return "~$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 10 { return String(format: "~$%.2f", value) }
        if value < 10_000 { return String(format: "~$%.0f", value) }
        return String(format: "~$%.1fk", value / 1_000)
    }

    /// A 0…1 share as an integer percentage, floored at `<1%` so a non-zero bucket never
    /// reads as `0%`.
    static func share(_ fraction: Double) -> String {
        let clamped = clampedShare(fraction)
        if clamped > 0, clamped < 0.005 { return "<1%" }
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// `fraction` into 0…1. `min(1, .nan)` returns 1 — Swift's `min` answers `y < x ? y : x`,
    /// and every comparison against NaN is false — so a bucket divided by a zero total would
    /// otherwise draw a full bar and read `100%`.
    static func clampedShare(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return max(0, min(1, fraction))
    }

    /// `<1m`, `34m`, `2h 41m`, `1d 3h`. No seconds — the panel is not a stopwatch.
    ///
    /// A span, not a countdown, which is why `MenuBarLabelText.compactDuration(until:now:)` is
    /// not reused: it renders anything under a minute as `now`, and a session that ran for forty
    /// seconds did not run `now`.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// `now`, `23m ago`, `3h ago`, `2d ago`. Dates in the future read as `now` rather than
    /// as a negative age, which is what a machine with a skewed clock produces.
    static func ago(_ date: Date, from now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// `128 msgs`, `1 msg`.
    static func messages(_ count: Int) -> String {
        count == 1 ? "1 msg" : "\(count) msgs"
    }
}
