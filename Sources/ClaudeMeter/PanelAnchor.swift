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
/// It corrects AppKit's placement rather than replacing it, and the correction has to be the *last*
/// write on the window or it is not a correction at all. That is the whole difficulty. Three things
/// hold it together, and each of them was arrived at by watching the frames go past.
///
/// **A resize provokes a re-anchor; a move does not.** This is the load-bearing fact. Every
/// `setFrame` that changes the size is followed by AppKit placing the panel by its own rule —
/// measured, this rule asked for x = 937 and the window came back at 500, over and over — while
/// `setFrameOrigin` is taken and kept. So the size is written once and the origin is then asserted
/// separately, in a loop, until the window agrees or the bound runs out.
///
/// **Nothing here may decline to look.** AppKit re-anchors from inside `setFrame` *and* again in a
/// later turn of the run loop, and both moves post notifications. A re-entrancy guard that
/// discards anything arriving mid-write discards exactly the report that matters, and the panel is
/// left where AppKit put it — measured, alternating between x = 845 and x = 380 frame by frame,
/// which is what the jitter was. So `reposition` is re-entrant and bounded by depth rather than
/// barred, and it always compares against where the window *is* rather than against what it was
/// last told to do. A rule that remembers its own requests stops defending the panel the moment
/// AppKit moves it behind that rule's back.
///
/// **Every frame asked for must be a frame the window can take.** Interpolated sizes are
/// fractional and window frames are not, so an unrounded target is 0.568pt short of itself
/// forever: the rule sees a window that did not obey, writes again, and provokes another
/// re-anchor — on every notification, for as long as the panel is open. `Frame.rounded` is the fix
/// for that, and it is load-bearing rather than tidiness.
///
/// Flicker is not the price of any of this, because window geometry is committed once per turn of
/// the run loop rather than per call — measured, while the frame went 684 → 664 → −388 → 664
/// in-process across one resize, the window server held the *previous* frame throughout and then
/// took only the last value. AppKit's off-screen intermediate is never drawn, provided nothing
/// forces a display mid-turn; see the `display:` argument below.
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

        /// How many `reposition` calls are on the stack.
        ///
        /// A boolean here — ignore anything arriving while we are writing — is the obvious guard
        /// and it is wrong, because the notification it discards is the only report of the one
        /// thing that has to be corrected: AppKit re-anchors the panel *from inside* `setFrame`,
        /// and swallowing that leaves its placement standing. Measured, that is a panel sitting
        /// at x=382 while this rule was asking for 845, alternating frame by frame.
        ///
        /// So nested corrections are allowed, and bounded instead. The recursion terminates on
        /// its own — a `reposition` whose window already has the target frame writes nothing and
        /// posts nothing — and the depth cap is only there for the case where the window refuses
        /// a frame outright, which must read as giving up rather than as a hang.
        private var repositionDepth = 0
        private static let maximumRepositionDepth = 4

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
                        MainActor.assumeIsolated {
                            self?.reposition()
                        }
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
            guard repositionDepth < Self.maximumRepositionDepth, let window else { return }
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

            // Rounded, because a window frame is whole points and an interpolated size is not.
            // See `PanelLayout.Frame.rounded`.
            let target = PanelLayout.Frame(
                x: x, y: y, width: size.width, height: size.height
            ).rounded()
            guard
                PanelLayout.shouldApply(target: target, current: PanelLayout.Frame(frame))
            else { return }

            repositionDepth += 1
            defer { repositionDepth -= 1 }
            // `display: false`, because the point of correcting AppKit rather than replacing it
            // is that the window server commits geometry once per turn of the run loop and never
            // draws the intermediate. Forcing a display here flushes each intermediate to the
            // screen instead, which is the difference between a glide and a flicker.
            window.setFrame(CGRect(target), display: false)

            // AppKit re-anchors the panel from inside that call — to the trailing-edge placement
            // this file exists to replace, which on a resize is a jump of most of a panel width.
            // It does not re-enter here to be corrected: the notification it posts arrives later
            // in the turn, by which time the frame it displaced has already been the one on
            // offer. So the origin is re-asserted here, in the same call, and re-checked, because
            // the assertion can itself provoke another anchoring pass. Bounded, because a fight
            // that does not converge must read as giving up rather than as a hang.
            let origin = CGPoint(x: target.x, y: target.y)
            for _ in 0..<Self.maximumRepositionDepth {
                guard abs(window.frame.minX - origin.x) > PanelLayout.frameTolerance
                    || abs(window.frame.minY - origin.y) > PanelLayout.frameTolerance
                else { break }
                window.setFrameOrigin(origin)
            }
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

// MARK: - Frame conversion

/// `PanelLayout` speaks in plain points so the placement rule can be tested without a window;
/// these are the two lines that cost.
extension PanelLayout.Frame {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

extension CGRect {
    init(_ frame: PanelLayout.Frame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
