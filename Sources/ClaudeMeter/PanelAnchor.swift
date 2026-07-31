import AppKit
import SwiftUI

// MARK: - Panel anchoring

/// Keeps the panel inside the screen as it resizes, so a panel that cannot widen to the right
/// widens to the left instead — smoothly, because the placement is a function of the width the
/// resize is already animating.
///
/// AppKit has two placements for a menu bar panel and no path between them. The leading edge sits
/// at the status item while the panel still fits to the right of it; the moment it does not, the
/// *trailing* edge goes to the status item's trailing edge instead. Measured with the item at x=686
/// on a 1792pt screen, stepping the width up: x held at 686 through a width of 1100, then went to
/// −388 at 1120. That is a jump of nearly the whole width, and nothing clamps it — the panel's
/// leading edge simply left the screen.
///
/// This substitutes one continuous rule for those two: hold the leading edge at the status item
/// while that fits, and past that hold the trailing edge just inside the screen, so any further
/// width moves the leading edge left. Because it depends only on the current width, there is no
/// threshold in it to jump at, and the width is exactly what SwiftUI is animating already (see
/// `PanelSize`) — so the sideways glide costs nothing beyond this arithmetic and arrives in step
/// with the resize.
///
/// It corrects AppKit's placement rather than replacing it, which is the only order on offer: the
/// hosting view resizes the window from the layout pass and AppKit re-anchors after that, both
/// arriving here as notifications. Correcting from them does not flicker, because window geometry
/// is committed once per turn of the run loop rather than per call — measured, while the frame went
/// 684 → 664 → −388 → 664 in-process across one resize, the window server held the *previous* frame
/// throughout and then took only the last value. AppKit's off-screen intermediate is never drawn.
extension PanelAnchor {
    /// The display the menu bar item hangs from, for callers that need to measure against the
    /// same screen this places the panel on. `nil` before the status item exists.
    @MainActor static var statusItemScreen: NSScreen? {
        AnchorView.statusItemWindow?.screen
    }
}

struct PanelAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {}

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.stopObserving()
    }
}

extension PanelAnchor {
    /// Carries no appearance and no content. It is installed only to reach the panel's `NSWindow`,
    /// which SwiftUI does not hand out, and it is sized 0×0 by its caller so it cannot draw or take
    /// a click by accident.
    @MainActor
    final class AnchorView: NSView {
        /// Breathing room at the screen edge rather than flush against it, near enough to the gap
        /// the rightmost menu bar item leaves.
        private static let screenGap: CGFloat = 8

        private var observers: [any NSObjectProtocol] = []

        /// The reposition below posts `didMove` itself, and this is what stops that arriving
        /// straight back here. The distance check further down would break the cycle too — the
        /// frame is updated before the notification lands — but only while every origin asked for
        /// is honoured, and the cost of being wrong about that is unbounded recursion.
        private var isRepositioning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }

            // Both notifications, because the two halves of a resize arrive separately: the
            // hosting view sets the new size, and AppKit re-anchors in a *second* frame change
            // after the resize notification has already been delivered.
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: nil
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.reposition() }
                    })
            }

            // The panel may already be open at a width that does not fit, since the expanded
            // sections are remembered across launches.
            reposition()
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        /// Moves the window to where the rule puts a panel of its current width.
        private func reposition() {
            guard !isRepositioning, let window else { return }
            // The screen the *status item* is on, not the one the window reports: a window pushed
            // past an edge belongs to whichever display it overlaps most, which on a multi-display
            // desk is how a mid-resize panel ends up measured against the wrong screen. The panel
            // hangs from one particular menu bar, and this is it.
            guard let statusItem = Self.statusItemWindow,
                let screen = statusItem.screen ?? window.screen ?? NSScreen.main
            else { return }

            let x = Self.originX(
                width: window.frame.width,
                statusItemLeading: statusItem.frame.minX,
                bounds: screen.visibleFrame)

            // Under a point apart is AppKit and this rule agreeing; moving anyway would post
            // another notification to no effect.
            guard abs(window.frame.minX - x) > 0.5 else { return }
            isRepositioning = true
            window.setFrameOrigin(CGPoint(x: x, y: window.frame.minY))
            isRepositioning = false
        }

        /// Leading edge under the status item while the panel fits to the right of it, and past
        /// that a trailing edge held inside the screen — which is the same thing as growing
        /// leftward. Monotonic and continuous in `width`, which is the property that makes the
        /// resize glide instead of jump.
        ///
        /// The outer clamp is for the case the inner one cannot express: a panel wider than the
        /// screen it hangs on has no placement that fits, and the leading edge is the end to keep,
        /// because that is where the content starts.
        static func originX(width: CGFloat, statusItemLeading: CGFloat, bounds: CGRect) -> CGFloat {
            let insideTrailingEdge = bounds.maxX - screenGap - width
            return max(bounds.minX + screenGap, min(statusItemLeading, insideTrailingEdge))
        }

        /// `MenuBarExtra` does not expose its `NSStatusItem`, so the item is found by window level.
        /// Unambiguous in practice: the item's window is an `NSStatusBarWindow` at `.statusBar`,
        /// while the panel itself sits at `.popUpMenu`, so this cannot pick up the panel it is
        /// about to move.
        fileprivate static var statusItemWindow: NSWindow? {
            NSApp.windows.first { $0.level == .statusBar }
        }
    }
}
