import Foundation
import Testing

@testable import UsageCore

/// `MenuBarLabelText` is pure string formatting over the values the app model already holds:
/// no filesystem, network, or Keychain access, and `now` is always supplied, so every
/// countdown here is deterministic.
struct MenuBarLabelTextTests {

    // MARK: - Fixtures

    private static let now = ISO8601.date(from: "2026-07-29T20:00:00Z")!

    /// The instant `minutes` from `now`, which is what a `resets_at` is.
    private func reset(inMinutes minutes: Double) -> Date {
        Self.now.addingTimeInterval(minutes * 60)
    }

    private func label(
        _ format: MenuBarFormat, percent: Double? = 17, projectedAtReset: Double? = nil,
        resetsAt: Date? = nil
    ) -> String {
        MenuBarLabelText.text(
            format: format, percent: percent, projectedAtReset: projectedAtReset,
            resetsAt: resetsAt, now: Self.now)
    }

    // MARK: - One format at a time

    @Test("iconOnly renders nothing at all, whatever it is handed")
    func iconOnlyIsEmpty() {
        #expect(label(.iconOnly) == "")
        #expect(
            label(.iconOnly, percent: 93.5, projectedAtReset: 120, resetsAt: reset(inMinutes: 161))
                == "")
        #expect(label(.iconOnly, percent: nil) == "")
    }

    @Test("percent renders the integer percentage and nothing else")
    func percentOnly() {
        #expect(label(.percent) == "17%")
        // Extra values are available but this format ignores them.
        #expect(
            label(.percent, projectedAtReset: 63, resetsAt: reset(inMinutes: 161)) == "17%")
    }

    @Test("percentAndPace renders `17% → 63%`")
    func percentAndPace() {
        #expect(label(.percentAndPace, projectedAtReset: 63) == "17% \u{2192} 63%")
        // A declining rolling window is a real, showable pace, not an error.
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 3) == "17% \u{2192} 3%")
    }

    @Test("percentAndTimeLeft renders `17% · 2h41m`")
    func percentAndTimeLeft() {
        #expect(
            label(.percentAndTimeLeft, resetsAt: reset(inMinutes: 161)) == "17% \u{b7} 2h41m")
    }

    @Test("Every format is covered, so no case falls through to an empty label")
    func everyFormatProducesItsOwnText() {
        let texts = MenuBarFormat.allCases.map {
            label($0, percent: 17, projectedAtReset: 63, resetsAt: reset(inMinutes: 161))
        }
        #expect(texts == ["17% \u{2192} 63%", "17%", "17% \u{b7} 2h41m", ""])
    }

    /// The settings screen advertises each format with a literal example. If the formatter and
    /// those labels drift apart the radio buttons start lying, so they are pinned together.
    @Test("The settings labels match what the formatter actually produces")
    func settingsLabelsMatchOutput() {
        for format in MenuBarFormat.allCases where format != .iconOnly {
            let produced = label(
                format, percent: 17, projectedAtReset: 63, resetsAt: reset(inMinutes: 161))
            #expect(format.settingsLabel.hasPrefix(produced))
        }
    }

    // MARK: - Flat-pace suppression

    @Test("A nil projection drops the arrow clause")
    func nilProjectionDropsPace() {
        #expect(label(.percentAndPace, projectedAtReset: nil) == "17%")
    }

    @Test("A projection within a point of the current value is noise and is dropped")
    func flatPaceIsSuppressed() {
        #expect(MenuBarLabelText.flatPaceTolerance == 1)
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 17) == "17%")
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 17.6) == "17%")
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 16.4) == "17%")
        // Exactly one point is still "within one point".
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 18) == "17%")
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 16) == "17%")
        // Just past the tolerance the clause comes back.
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: 18.2) == "17% \u{2192} 18%")
    }

    @Test("The tolerance is wide enough that the label can never read `17% → 17%`")
    func identicalRenderingsNeverBothAppear() {
        // Any two values that round to the same integer are under a point apart, so the
        // tolerance subsumes them. Sweep the rounding bucket to prove it.
        for offset in stride(from: -0.49, through: 0.49, by: 0.07) {
            let text = label(.percentAndPace, percent: 17, projectedAtReset: 17 + offset)
            #expect(text == "17%")
        }
    }

    @Test("A pace clause survives when only the projection is large")
    func steepPaceIsShown() {
        #expect(label(.percentAndPace, percent: 7, projectedAtReset: 148) == "7% \u{2192} 148%")
    }

    /// The tolerance alone does not cover this: clamping maps far-apart values onto one
    /// string, and `0% → 0%` is the same noise the tolerance suppresses.
    @Test("Values that clamp onto the same digits drop the clause, never `0% → 0%`")
    func clampedDuplicatesDropThePace() {
        // A negative utilization clamps to 0% here, and `ProjectionEngine` already floors its
        // projection at 0, so both sides read `0%` while being 7 points apart.
        #expect(label(.percentAndPace, percent: -7, projectedAtReset: 0) == "0%")
        #expect(label(.percentAndPace, percent: -12, projectedAtReset: -3) == "0%")
        // Same collapse at the top of the range, whatever the ceiling is set to.
        let absurd = label(.percentAndPace, percent: 5e5, projectedAtReset: 9e9)
        #expect(!absurd.contains("\u{2192}"))
    }

    // MARK: - Missing values

    @Test("A nil percentage renders an em dash for every text format")
    func nilPercentRendersDash() {
        for format in MenuBarFormat.allCases where format != .iconOnly {
            #expect(
                label(format, percent: nil, projectedAtReset: 63, resetsAt: reset(inMinutes: 161))
                    == "\u{2014}")
        }
    }

    @Test("A nil reset time degrades percentAndTimeLeft to the percentage alone")
    func nilResetDegradesToPercent() {
        #expect(label(.percentAndTimeLeft, resetsAt: nil) == "17%")
    }

    /// A poll that failed for a few minutes leaves a `resets_at` in the past in the cached
    /// snapshot, and the menu bar keeps rendering it until the next success.
    @Test("A stale reset time reads `now` rather than a negative countdown")
    func staleResetInTimeLeftFormat() {
        #expect(label(.percentAndTimeLeft, resetsAt: reset(inMinutes: -5)) == "17% \u{b7} now")
    }

    @Test("A non-finite percentage degrades instead of trapping the Int conversion")
    func nonFinitePercentIsUnavailable() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(label(.percent, percent: value) == "\u{2014}")
            #expect(label(.percentAndPace, percent: value, projectedAtReset: 63) == "\u{2014}")
        }
        // A non-finite projection loses only the clause it belongs to.
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: Double.nan) == "17%")
        #expect(label(.percentAndPace, percent: 17, projectedAtReset: Double.infinity) == "17%")
    }

    // MARK: - Percentage rounding

    @Test("Percentages round to the nearest point")
    func percentagesRoundToNearest() {
        #expect(label(.percent, percent: 0) == "0%")
        #expect(label(.percent, percent: 16.6) == "17%")
        #expect(label(.percent, percent: 17.4) == "17%")
        #expect(label(.percent, percent: 17.5) == "18%")
        #expect(label(.percent, percent: 93.5) == "94%")
        #expect(label(.percent, percent: 100) == "100%")
    }

    @Test("A negative percentage clamps to zero rather than reading -0%")
    func negativePercentClamps() {
        #expect(label(.percent, percent: -0.4) == "0%")
        #expect(label(.percent, percent: -12) == "0%")
    }

    // MARK: - compactDuration

    @Test("Under a minute reads `now`")
    func subMinuteReadsNow() {
        #expect(MenuBarLabelText.compactDuration(until: reset(inMinutes: 0), now: Self.now) == "now")
        #expect(
            MenuBarLabelText.compactDuration(
                until: Self.now.addingTimeInterval(59), now: Self.now) == "now")
        #expect(
            MenuBarLabelText.compactDuration(
                until: Self.now.addingTimeInterval(0.5), now: Self.now) == "now")
    }

    @Test("A window that has already reset reads `now`, not a negative duration")
    func pastResetReadsNow() {
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: -90), now: Self.now) == "now")
    }

    @Test("Minutes-only durations carry no hour component")
    func minutesOnly() {
        #expect(
            MenuBarLabelText.compactDuration(
                until: Self.now.addingTimeInterval(60), now: Self.now) == "1m")
        #expect(MenuBarLabelText.compactDuration(until: reset(inMinutes: 14), now: Self.now) == "14m")
        #expect(MenuBarLabelText.compactDuration(until: reset(inMinutes: 59), now: Self.now) == "59m")
    }

    @Test("Hours and minutes render as `2h41m`")
    func hoursAndMinutes() {
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 161), now: Self.now) == "2h41m")
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 60), now: Self.now) == "1h")
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 65), now: Self.now) == "1h5m")
        // The full 5-hour window.
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 300), now: Self.now) == "5h")
    }

    @Test("Seconds are truncated, never rounded up past the time actually left")
    func secondsTruncate() {
        let almostNextMinute = Self.now.addingTimeInterval(14 * 60 + 59)
        #expect(MenuBarLabelText.compactDuration(until: almostNextMinute, now: Self.now) == "14m")
        let almostNextHour = Self.now.addingTimeInterval(59 * 60 + 59.9)
        #expect(MenuBarLabelText.compactDuration(until: almostNextHour, now: Self.now) == "59m")
    }

    @Test("A weekly window a day or more out uses the day form")
    func dayForm() {
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 24 * 60), now: Self.now) == "1d")
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 3 * 24 * 60 + 125), now: Self.now)
                == "3d2h")
        // 7 days minus a minute — the widest a weekly reset can legitimately be.
        #expect(
            MenuBarLabelText.compactDuration(until: reset(inMinutes: 7 * 24 * 60 - 1), now: Self.now)
                == "6d23h")
    }

    @Test("An absurd or non-finite reset time clamps instead of trapping")
    func absurdResetIsClamped() {
        #expect(MenuBarLabelText.compactDuration(until: .distantFuture, now: Self.now) == "365d")
        #expect(MenuBarLabelText.compactDuration(until: .distantPast, now: Self.now) == "now")
        // An infinite interval is absurdly large, not imminent: it clamps like `distantFuture`
        // rather than claiming the window is resetting right now.
        #expect(
            MenuBarLabelText.compactDuration(
                until: Date(timeIntervalSinceReferenceDate: .infinity), now: Self.now) == "365d")
        #expect(
            MenuBarLabelText.compactDuration(
                until: Date(timeIntervalSinceReferenceDate: -.infinity), now: Self.now) == "now")
        // A NaN interval says nothing about how much time is left, so it degrades to `now`.
        let notANumber = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(MenuBarLabelText.compactDuration(until: notANumber, now: Self.now) == "now")
        #expect(MenuBarLabelText.compactDuration(until: Self.now, now: notANumber) == "now")
    }

    /// The two integer conversions in this file round differently on purpose — nearest for a
    /// percentage, down for a countdown that must never overstate — so they are pinned in one
    /// place to stop a later edit from unifying them.
    @Test("Percentages round to nearest while the countdown truncates, in the same label")
    func roundingRulesDifferPerField() {
        #expect(
            label(.percentAndTimeLeft, percent: 17.9, resetsAt: reset(inMinutes: 161.9))
                == "18% \u{b7} 2h41m")
    }

    // MARK: - Against real projection output

    /// End to end on the shapes the engine actually produces, so the formatter is exercised
    /// with a `Projection` rather than hand-picked doubles.
    @Test("A measured projection formats through every text variant")
    func formatsAProjection() throws {
        let resetsAt = reset(inMinutes: 161)
        let snapshot = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 17, resetsAt: resetsAt), sevenDay: nil,
            limits: [], extraUsage: nil, fetchedAt: Self.now)
        // 17 points now, rising ~17 points/hour over 2h41m of window: about 63% at reset.
        let series = (0..<9).map { index -> Sample in
            let t = Self.now.addingTimeInterval(-Double(8 - index) * 5 * 60)
            return Sample(
                t: t, fiveHourPct: 5 + 17 * (Double(index) * 5 / 60), fiveHourResetsAt: resetsAt,
                sevenDayPct: nil, sevenDayResetsAt: nil)
        }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour, snapshot: snapshot, samples: series, events: [], now: Self.now))
        #expect(projection.basis == .measured)

        let paced = MenuBarLabelText.text(
            format: .percentAndPace, percent: snapshot.fiveHour?.utilization,
            projectedAtReset: projection.projectedAtReset, resetsAt: projection.resetsAt,
            now: Self.now)
        #expect(paced == "17% \u{2192} 63%")

        let timed = MenuBarLabelText.text(
            format: .percentAndTimeLeft, percent: snapshot.fiveHour?.utilization,
            projectedAtReset: projection.projectedAtReset, resetsAt: projection.resetsAt,
            now: Self.now)
        #expect(timed == "17% \u{b7} 2h41m")
    }
}
