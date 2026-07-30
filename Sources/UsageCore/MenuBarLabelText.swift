import Foundation

// MARK: - Menu bar label text

/// The text half of the menu bar item — everything to the right of the rasterised ring.
///
/// This is the one presentation type that lives in `UsageCore` rather than the app target:
/// `MenuBarExtra`'s label can only be built from `Text` and `Image`, so all four formats
/// collapse to a single string, and a string is testable without instantiating SwiftUI.
///
/// The caller supplies `now` instead of this reading the clock, so the countdown is a pure
/// function of its arguments and a poll can be replayed at a fixed instant.
public enum MenuBarLabelText {
    /// A projected value no further than this from the current one is pace noise, not a
    /// trend. Any two percentages that render as the same integer differ by less than a
    /// point, so this covers most of the way to never rendering `42% → 42%`; the clamps in
    /// `percentText` can still collapse two distant values onto one string, which `text`
    /// checks for separately.
    ///
    /// Internal rather than public: the contract's surface for this file is the two
    /// functions below, and nothing outside `UsageCore` needs the number.
    static let flatPaceTolerance: Double = 1

    /// Ceiling for the `Int` conversions below. `Int(_:)` traps on a `Double` too large to
    /// represent, and both the percentage and `resets_at` arrive from JSON we do not own —
    /// a corrupt payload must degrade to a silly-looking label, never to a crash.
    private static let percentCeiling: Double = 9_999
    private static let durationCeiling: TimeInterval = 365 * 24 * 3600

    private static let unavailable = "—"
    private static let paceArrow = "→"
    private static let separator = "·"

    /// The text beside the ring for a given format. Empty string for `.iconOnly`.
    ///
    /// Without a percentage there is nothing to decorate, so a nil `percent` renders
    /// `—` for every text format rather than a bare pace or countdown.
    public static func text(
        format: MenuBarFormat, percent: Double?, projectedAtReset: Double?,
        resetsAt: Date?, now: Date
    ) -> String {
        switch format {
        case .iconOnly:
            return ""

        case .percent:
            return percentText(percent) ?? unavailable

        case .percentAndPace:
            guard let percent, let current = percentText(percent) else { return unavailable }
            // `projected != current` is not implied by the tolerance: `percentText` clamps,
            // so two values more than a point apart can still render identically (a negative
            // utilization and a projection the engine floored at 0 both read `0%`), and
            // `0% → 0%` is exactly the noise the tolerance exists to suppress.
            guard let projectedAtReset, let projected = percentText(projectedAtReset),
                abs(projectedAtReset - percent) > flatPaceTolerance, projected != current
            else { return current }
            return "\(current) \(paceArrow) \(projected)"

        case .percentAndTimeLeft:
            guard let current = percentText(percent) else { return unavailable }
            guard let resetsAt else { return current }
            return "\(current) \(separator) \(compactDuration(until: resetsAt, now: now))"
        }
    }

    /// "2h41m", "14m", "now" — compact, no seconds.
    ///
    /// Truncated rather than rounded, so the label never claims more time than is left, and
    /// deliberately blind to seconds: a menu bar item that reflows every second is a
    /// distraction, and at 60s polling the seconds digit would be wrong anyway. Anything
    /// under a minute — including a window that has already reset — reads `now`.
    ///
    /// Spans of a day or more render as `3d2h`. Only the 5-hour window reaches the menu bar,
    /// but the weekly window uses this too and `167h59m` is not a compact label.
    public static func compactDuration(until date: Date, now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        // A NaN interval — either date corrupt — fails this comparison and reads `now`,
        // since an unknowable remaining time is not a large one. `+∞` passes and is clamped
        // by `durationCeiling` below: a reset absurdly far out must not report itself as
        // imminent, which is the one way this string can be actively misleading.
        guard remaining >= 60 else { return "now" }

        let totalMinutes = Int(min(remaining, durationCeiling) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// `42%`, rounded to the nearest point — the same rounding `MenuBarIcon` memoises its ring
    /// on, so the number and the fill never disagree. `nil` when there is no usable value;
    /// negatives clamp to zero, since utilization is a share of a limit and `-0%` is nonsense.
    private static func percentText(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return "\(Int(min(max(value, 0), percentCeiling).rounded()))%"
    }
}
