import AppKit
import SwiftUI
import UsageCore

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
    /// The size the panel's window should have. Comes from `PanelSize`, which is `Animatable`,
    /// so this is the *interpolated* size on each frame of a resize rather than the destination
    /// — which is what keeps the window gliding rather than jumping to its final size while the
    /// content animates underneath it.
    var size: CGSize

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.apply(size: size)
    }

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
        private var observers: [any NSObjectProtocol] = []

        /// The reposition below posts `didMove` itself, and this is what stops that arriving
        /// straight back here. The distance check further down would break the cycle too — the
        /// frame is updated before the notification lands — but only while every origin asked for
        /// is honoured, and the cost of being wrong about that is unbounded recursion.
        private var isRepositioning = false

        /// Zero until the first layout has measured the content.
        private var desiredSize: CGSize = .zero

        /// The size SwiftUI wants, imposed on the window rather than left to it.
        ///
        /// The hosting view grows the window to fit its content but does not reliably shrink it:
        /// collapsing a section took the content from 676×940 to 320×486 and left the window at
        /// 676×940, which centred the smaller content inside it and put the panel 257pt down the
        /// screen, detached from the menu bar. No resize notification is posted for a resize that
        /// does not happen, which is why correcting the origin alone could not reach it.
        func apply(size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            desiredSize = size
            reposition()
        }

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

            let frame = window.frame
            let bounds = screen.visibleFrame
            // The size SwiftUI asked for, falling back to the window's own while nothing has
            // been measured yet.
            let size = desiredSize == .zero ? frame.size : desiredSize
            let x = PanelLayout.originX(
                width: size.width, statusItemLeading: statusItem.frame.minX,
                boundsMinX: bounds.minX, boundsMaxX: bounds.maxX)
            // Both axes, because a resize that changes only the height still moves the top edge:
            // AppKit holds the origin, the origin is the bottom-left, so the panel comes away
            // from the menu bar by whatever height it lost. Checking x alone used to return
            // early on exactly those resizes and leave it there.
            let y = PanelLayout.originY(height: size.height, boundsMaxY: bounds.maxY)

            // Under a point apart on every term is AppKit and this rule agreeing; setting the
            // frame anyway would post another notification to no effect.
            let target = CGRect(x: x, y: y, width: size.width, height: size.height)
            guard abs(frame.minX - target.minX) > 0.5 || abs(frame.minY - target.minY) > 0.5
                || abs(frame.width - target.width) > 0.5
                || abs(frame.height - target.height) > 0.5
            else { return }
            isRepositioning = true
            window.setFrame(target, display: true)
            isRepositioning = false
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
