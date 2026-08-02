import Foundation

/// The one/two-column decision, as arithmetic over measured heights.
///
/// Lives in `UsageCore` rather than beside the view for one reason: the failure mode this rule
/// has to avoid is an oscillation between the two forms, and an oscillation is a property of a
/// *sequence* of decisions. Testing for it means driving the rule round a loop with the heights
/// each form produces, which needs the rule to be callable without SwiftUI.
///
/// Every dimension here is in points.
public enum PanelLayout {
    /// Below this the second column is not paid for.
    ///
    /// It costs 341pt of width (661 against 320) and this asks a little under two-thirds of that
    /// back in height, which is deliberately generous to the split: the panel can grow sideways
    /// across the whole screen, where height is the dimension it has already run out of by the
    /// time the question is asked.
    public static let minimumSplitSaving: Double = 200

    /// Never change form on a margin thinner than the difference between the two forms' own
    /// measurements.
    ///
    /// The blocks are laid out 8pt apart in the two forms — a 300pt column against the single
    /// column's 292 — so a wrapped caption can gain or lose a line across the switch, moving both
    /// the substituted height and the saving by a few points. With no band at all that difference
    /// is enough on its own to satisfy the opposite condition on the very next pass, and the panel
    /// changes form every frame.
    ///
    /// 60pt is around three wrapped caption lines. It is only enough because the *other* term
    /// that used to vary with width — the health notice, which re-wraps from roughly 251pt to
    /// 592pt between the forms and can differ by 65pt on its own — is pinned to a single width by
    /// the view instead of being left for this band to absorb. See `stackedHeight`.
    public static let hysteresis: Double = 60

    /// What the second column buys: the shorter block moves up beside the taller one instead of
    /// sitting under it, so the height saved is the whole of the shorter block plus the gap that
    /// separated them.
    ///
    /// Heights of zero are a pass that has not measured yet, and read here as a saving too small
    /// to act on — the safe answer for a pass that knows nothing.
    public static func splitSaving(leading: Double, daily: Double, stackedGap: Double) -> Double {
        min(leading, daily) + stackedGap
    }

    /// The height the content *would* have in one column, whichever form it is in now.
    ///
    /// Being able to ask that from inside the other form is what keeps the decision from feeding
    /// on itself. The obvious version — widen when the measured height exceeds the screen —
    /// oscillates, because widening is precisely what makes the measured height small again,
    /// which satisfies the condition to narrow, which makes it large again.
    ///
    /// So the two blocks that swap columns are measured separately and the arrangement is
    /// substituted rather than re-measured. Side by side they occupy `max(leading, daily)`;
    /// stacked they occupy `leading + gap + daily`. Everything else on the panel cancels — but
    /// only because it is width-invariant by construction, which is a standing requirement on the
    /// view and not a happy accident: the health notice wraps its text and had to be pinned to a
    /// fixed width before this identity held. A width-dependent term left outside the probes
    /// re-opens the loop, and it only takes 60pt of difference to do it.
    ///
    /// Returns 0 when a block has not been measured yet, meaning "no estimate".
    public static func stackedHeight(
        measured: Double, isWide: Bool, leading: Double, daily: Double, stackedGap: Double
    ) -> Double {
        guard measured > 0 else { return 0 }
        guard isWide else { return measured }
        guard leading > 0, daily > 0 else { return 0 }
        return measured - max(leading, daily) + leading + stackedGap + daily
    }

    /// Breathing room at the screen edge rather than flush against it, near enough to the gap
    /// the rightmost menu bar item leaves.
    public static let screenGap: Double = 8

    /// Leading edge under the status item while the panel fits to the right of it, and past that
    /// a trailing edge held inside the screen — which is the same thing as growing leftward.
    /// Monotonic and continuous in `width`, which is the property that makes the resize glide
    /// instead of jump.
    ///
    /// The outer clamp is for the case the inner one cannot express: a panel wider than the
    /// screen it hangs on has no placement that fits, and the leading edge is the end to keep,
    /// because that is where the content starts.
    public static func originX(
        width: Double, statusItemLeading: Double, boundsMinX: Double, boundsMaxX: Double
    ) -> Double {
        let insideTrailingEdge = boundsMaxX - screenGap - width
        return max(boundsMinX + screenGap, min(statusItemLeading, insideTrailingEdge))
    }

    /// A window rectangle in AppKit's coordinates, as plain numbers.
    ///
    /// Declared here rather than borrowing `CGRect` so this module keeps saying what it says
    /// everywhere else — points, no graphics framework — and so the placement rule stays
    /// testable without a window to hang it on.
    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// The same rectangle in whole points — which is the only kind a window has.
        ///
        /// The sizes arriving here are interpolated, so they are fractional; the frame the
        /// window ends up with is not. Asked for 941.568 it takes 941, and a rule that then
        /// compares the two finds them 0.568 apart, decides the window did not do as it was
        /// told, and asks again — on every notification, for as long as the panel is open.
        /// Rounding the target first is what makes "did the window take what it was given" a
        /// question with a stable answer, and everything else here depends on that.
        public func rounded() -> Frame {
            Frame(
                x: x.rounded(), y: y.rounded(), width: width.rounded(),
                height: height.rounded())
        }
    }

    /// Sub-point agreement, in points. Below this AppKit and this rule are saying the same thing.
    public static let frameTolerance: Double = 0.5

    /// Whether the window is somewhere other than where it belongs.
    ///
    /// Deliberately compares against the window's *current* frame and nothing else. AppKit
    /// re-anchors a menu bar panel on its own account — during a resize and again after one —
    /// so the placement has to be defended continuously rather than asserted once and assumed;
    /// a rule that remembers what it last asked for stops correcting exactly when AppKit moves
    /// the panel behind its back.
    public static func shouldApply(target: Frame, current: Frame) -> Bool {
        !(abs(target.x - current.x) <= frameTolerance
            && abs(target.y - current.y) <= frameTolerance
            && abs(target.width - current.width) <= frameTolerance
            && abs(target.height - current.height) <= frameTolerance)
    }

    /// Top edge under the menu bar, expressed as the bottom-left origin AppKit wants.
    ///
    /// The panel hangs from the menu bar, so the edge that must not move is the top — and in
    /// AppKit's coordinates that is the one an origin does not name. Holding `minY` across a
    /// resize, which is what preserving the origin does, pins the *bottom*: shrink the content
    /// and the top falls away from the menu bar by exactly the height that was lost. Collapsing
    /// a section that took the panel from two columns to one dropped it 290pt down the screen,
    /// leaving it floating unattached in the middle of the display.
    ///
    /// No clamp against the bottom of the screen. A panel taller than the screen should keep its
    /// top and scroll, and the height cap means it cannot get there anyway.
    public static func originY(height: Double, boundsMaxY: Double) -> Double {
        boundsMaxY - max(0, height)
    }

    /// Whether the panel should be in its two-column form.
    ///
    /// Two conditions, both carrying the hysteresis band on the side that keeps the current form,
    /// so the panel is reluctant to *leave* where it is rather than reluctant to arrive.
    ///
    /// The second is the part a height alone cannot say. A panel that overruns because one block
    /// is enormous and the other is a few collapsed headers has nothing worth moving: the split
    /// would still be as tall as the big block and would cost the full width. That case stays
    /// narrow and scrolls, which is the right answer and not a failure to widen.
    ///
    /// Except when the split is what makes the content *fit*. A fixed saving threshold asks
    /// "is this worth the width" in the abstract, and gets the answer wrong at the one point
    /// where the question has an obvious answer: if moving the shorter block up beside the
    /// taller one brings the panel back inside the screen, it is worth it however few points
    /// that took. Without this the rule is also discontinuous in a way a reader would feel —
    /// with the breakdown open, collapsing one stats group could drop the saving from 205 to
    /// 180 and turn a two-column panel that fitted into a one-column panel that scrolls.
    public static func wantsWide(
        stackedHeight: Double, splitSaving: Double, maximumHeight: Double, isWide: Bool
    ) -> Bool {
        guard stackedHeight > 0 else { return isWide }
        let slack = isWide ? hysteresis : 0
        guard stackedHeight > maximumHeight - slack else { return false }
        let worthIt = splitSaving + slack >= minimumSplitSaving
        let solvesIt = stackedHeight - splitSaving <= maximumHeight + slack
        return worthIt || solvesIt
    }
}
