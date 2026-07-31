import Foundation
import Testing

@testable import UsageCore

/// The layout rule's one real failure mode is an oscillation, which is a property of a sequence
/// of decisions rather than of any single one. These drive it round the loop.
struct PanelLayoutTests {

    /// The view's own `stackedGap`: two 12pt stack spacings either side of a 1pt divider.
    private static let gap: Double = 25

    /// Runs the rule to a fixed point, feeding each decision the height its own form produces.
    ///
    /// This is the loop the app performs: a form change re-lays out the panel, the new
    /// measurement arrives, and the rule is asked again. `nil` means it never settled.
    private func settle(
        leading: Double, daily: Double, maximumHeight: Double, constant: Double = 0,
        startWide: Bool = false, limit: Int = 40
    ) -> Bool? {
        var isWide = startWide
        var seen: [Bool] = [isWide]
        for _ in 0..<limit {
            // What the panel would measure in the form it is currently in.
            let measured = isWide
                ? constant + max(leading, daily)
                : constant + leading + Self.gap + daily
            let stacked = PanelLayout.stackedHeight(
                measured: measured, isWide: isWide, leading: leading, daily: daily,
                stackedGap: Self.gap)
            let wanted = PanelLayout.wantsWide(
                stackedHeight: stacked,
                splitSaving: PanelLayout.splitSaving(
                    leading: leading, daily: daily, stackedGap: Self.gap),
                maximumHeight: maximumHeight, isWide: isWide)
            if wanted == isWide { return isWide }
            isWide = wanted
            seen.append(isWide)
        }
        return nil
    }

    @Test("The substitution reconstructs the one-column height from a two-column measurement")
    func substitutionIsAnIdentity() {
        let leading = 300.0
        let daily = 485.0
        let constant = 167.0
        let narrow = constant + leading + Self.gap + daily
        let wide = constant + max(leading, daily)

        let reconstructed = PanelLayout.stackedHeight(
            measured: wide, isWide: true, leading: leading, daily: daily, stackedGap: Self.gap)
        #expect(abs(reconstructed - narrow) < 1e-9)

        // In the narrow form there is nothing to substitute — the measurement already is the
        // stacked height.
        #expect(
            PanelLayout.stackedHeight(
                measured: narrow, isWide: false, leading: leading, daily: daily,
                stackedGap: Self.gap) == narrow)
    }

    @Test("The rule settles rather than flipping, over a wide sweep of block heights")
    func alwaysConverges() {
        // The heights either side of every threshold the rule has, from both starting forms.
        for leading in stride(from: 40.0, through: 700, by: 20) {
            for daily in stride(from: 40.0, through: 900, by: 20) {
                for start in [false, true] {
                    let settled = settle(
                        leading: leading, daily: daily, maximumHeight: 1042, constant: 167,
                        startWide: start)
                    #expect(
                        settled != nil,
                        "did not settle: leading \(leading), daily \(daily), startWide \(start)")
                }
            }
        }
    }

    @Test("A width-dependent term outside the probes is what breaks convergence")
    func aWidthDependentConstantWouldOscillate() {
        // The defect the health notice would have caused, reproduced by making the constant
        // differ between the forms and driving the same loop. This is not a claim about the
        // shipped rule — it is why the view pins the notice to one width.
        let leading = 300.0, daily = 485.0, maximumHeight = 1042.0
        var isWide = false
        var flips = 0
        for _ in 0..<20 {
            // 238 stacked against 167 side by side: a notice that re-wraps by 71pt.
            let measured = isWide ? 167 + max(leading, daily) : 238 + leading + Self.gap + daily
            let stacked = PanelLayout.stackedHeight(
                measured: measured, isWide: isWide, leading: leading, daily: daily,
                stackedGap: Self.gap)
            let wanted = PanelLayout.wantsWide(
                stackedHeight: stacked,
                splitSaving: PanelLayout.splitSaving(
                    leading: leading, daily: daily, stackedGap: Self.gap),
                maximumHeight: maximumHeight, isWide: isWide)
            if wanted != isWide { flips += 1 }
            isWide = wanted
        }
        // It never settles, which is exactly why that term is not allowed to vary with width.
        #expect(flips > 10)

        // With the term pinned — the same number in both forms — the identical geometry settles.
        #expect(
            settle(
                leading: leading, daily: daily, maximumHeight: maximumHeight, constant: 238)
                != nil)
    }

    @Test("The band keeps the current form rather than resisting arrival at it")
    func hysteresisFavoursTheCurrentForm() {
        let saving = 400.0
        let cap = 1000.0
        // Just over the cap: narrow widens.
        #expect(
            PanelLayout.wantsWide(
                stackedHeight: cap + 1, splitSaving: saving, maximumHeight: cap, isWide: false))
        // The same height, already wide, stays wide — and stays wide until it is a full band
        // under the cap.
        #expect(
            PanelLayout.wantsWide(
                stackedHeight: cap - PanelLayout.hysteresis + 1, splitSaving: saving,
                maximumHeight: cap, isWide: true))
        #expect(
            !PanelLayout.wantsWide(
                stackedHeight: cap - PanelLayout.hysteresis, splitSaving: saving,
                maximumHeight: cap, isWide: true))
        // The saving test carries the band the same way round. Measured at a height the split
        // cannot rescue, so the "it makes it fit" disjunct is out of the way and the threshold
        // is what is being tested — at `cap + 1` a 199pt saving fits the content and wins on
        // that ground instead.
        let hopeless = cap * 2
        #expect(
            !PanelLayout.wantsWide(
                stackedHeight: hopeless, splitSaving: PanelLayout.minimumSplitSaving - 1,
                maximumHeight: cap, isWide: false))
        #expect(
            PanelLayout.wantsWide(
                stackedHeight: hopeless,
                splitSaving: PanelLayout.minimumSplitSaving - PanelLayout.hysteresis,
                maximumHeight: cap, isWide: true))
    }

    @Test("A split that neither fits the content nor buys back its width leaves the panel narrow")
    func aPointlessSplitIsDeclined() {
        // One enormous block beside a few collapsed headers: side by side the panel is still as
        // tall as the big block, so the split costs 341pt of width to save 165 of height and
        // still overruns. Narrow and scrolling is the honest answer.
        #expect(
            !PanelLayout.wantsWide(
                stackedHeight: 2200, splitSaving: PanelLayout.splitSaving(
                    leading: 140, daily: 2000, stackedGap: Self.gap),
                maximumHeight: 1042, isWide: false))
        // The case the feature exists for: both blocks substantial, so moving one up beside the
        // other buys back real height.
        #expect(
            PanelLayout.wantsWide(
                stackedHeight: 1100, splitSaving: PanelLayout.splitSaving(
                    leading: 300, daily: 700, stackedGap: Self.gap),
                maximumHeight: 1042, isWide: false))
    }

    @Test("A small saving still wins when it is the thing that makes the content fit")
    func aSplitThatFitsTheContentIsTaken() {
        // Leading collapsed to 155pt beside a 750pt breakdown. The saving is 180 — under the
        // 200 threshold — but stacked 1097 against a 1042 cap becomes 917 side by side, which
        // fits. Judged on the threshold alone this panel would scroll for the sake of 20pt.
        let saving = PanelLayout.splitSaving(leading: 155, daily: 750, stackedGap: Self.gap)
        #expect(saving < PanelLayout.minimumSplitSaving)
        #expect(
            PanelLayout.wantsWide(
                stackedHeight: 1097, splitSaving: saving, maximumHeight: 1042, isWide: false))

        // Same saving, but far enough over the cap that splitting does not rescue it: declined.
        #expect(
            !PanelLayout.wantsWide(
                stackedHeight: 1400, splitSaving: saving, maximumHeight: 1042, isWide: false))
    }

    @Test("An unmeasured pass changes nothing")
    func unmeasuredPassesHoldTheCurrentForm() {
        #expect(
            PanelLayout.stackedHeight(
                measured: 0, isWide: false, leading: 0, daily: 0, stackedGap: Self.gap) == 0)
        // Wide with neither block measured yet: no estimate, rather than a wrong one.
        #expect(
            PanelLayout.stackedHeight(
                measured: 600, isWide: true, leading: 0, daily: 0, stackedGap: Self.gap) == 0)
        // And a zero estimate holds whichever form the panel is in, so it cannot latch.
        for wide in [false, true] {
            #expect(
                PanelLayout.wantsWide(
                    stackedHeight: 0, splitSaving: 400, maximumHeight: 1042, isWide: wide) == wide)
        }
    }
}
