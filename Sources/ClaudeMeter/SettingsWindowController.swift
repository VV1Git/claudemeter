import AppKit
import SwiftUI

// MARK: - Settings window

/// Owns the settings window directly instead of using SwiftUI's `Settings` scene.
///
/// The scene does not work dependably in a menu bar app. The app runs `.accessory` so it has no
/// Dock icon, and an accessory app cannot reliably take focus: `SettingsLink` would fire, the
/// window would open, and nothing would bring it forward — so it stayed behind other windows or on
/// whichever Space it was last used on, which from the user's side is "clicking the gear does
/// nothing, sometimes". Coaxing the scene's window after the fact (activate, order front, join the
/// active Space) fixed it only intermittently, because the scene decides when the window exists and
/// whether the click is honoured at all.
///
/// Owning an `NSWindow` removes the scene from the equation: the window is created when asked for,
/// and shown by code that runs on the click every time.
///
/// The one thing that genuinely requires the policy switch is focus. `.accessory` apps are not
/// meant to own key windows, so while the settings window is up the app becomes `.regular` and
/// reverts on close. The visible cost is a Dock icon for exactly as long as the window is open,
/// which is the usual trade menu bar apps make and is worth it for a window that actually appears.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var model: AppModel?

    private override init() { super.init() }

    /// Injected once at launch so the pane shows live values. Held weakly — the model outlives this
    /// controller in practice, and a strong reference here would be a retain cycle through the
    /// hosted view.
    func attach(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        // Before activating: an accessory app has no business owning a key window, and asking for
        // one while in that policy is what made this unreliable.
        NSApp.setActivationPolicy(.regular)

        // Follow the user to whatever desktop they are on, rather than making them find the Space
        // the window was last used on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        Self.recentreIfStranded(window)

        // `ignoringOtherApps` is required rather than polite: the user just clicked a menu bar item
        // while some other app was frontmost, so a cooperative activation request is dropped.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // One retry, on the next turn of the run loop. A single activation request is sometimes
        // dropped — observed while another app was mid-transition — and a dropped one is precisely
        // the "clicking the gear did nothing" symptom. Bounded to one extra attempt rather than a
        // loop, so a genuinely refused activation cannot spin.
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Last resort, and the important one: macOS can refuse to make an app frontmost, and
            // `makeKeyAndOrderFront` does nothing for a window whose app is not active. This orders
            // the window up regardless, so the worst case is a visible window that has to be
            // clicked to focus — not the invisible one this whole class exists to prevent.
            window.orderFrontRegardless()
        }
    }

    /// Fallback content size. `NSHostingController` reported a 28-point-tall window — a title bar
    /// and nothing else — when left to infer its own height from a grouped `Form`, so a concrete
    /// size is set rather than trusted.
    private static let defaultContentSize = NSSize(width: 420, height: 560)
    private static let minimumContentSize = NSSize(width: 420, height: 320)

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: rootView())
        // Neither automatic answer is usable: left to itself the controller reported a 28-point
        // height for a grouped `Form`, and `.preferredContentSize` reported the form's full
        // expanded height — 1045 points, nearly a whole screen. The window is sized explicitly
        // instead and the form scrolls inside it.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "ClaudeMeter Settings"
        // Resizable so content can never be permanently clipped by a size guess of mine.
        window.styleMask = [.titled, .closable, .resizable]
        // The window is reused across openings, so it must survive being closed.
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.setContentSize(Self.defaultContentSize)

        // Remembers position and size between launches, like a normal settings window. This
        // restores a frame, so anything depending on the frame comes after it.
        window.setFrameAutosaveName("ClaudeMeterSettingsWindow")
        Self.clampToUsableHeight(window)

        // Applied only now, deliberately. Set before the restore above, AppKit silently grows a
        // collapsed saved frame up to this minimum, and the clamp then sees a height that looks
        // chosen rather than broken — leaving the window at the minimum instead of a usable size.
        window.contentMinSize = Self.minimumContentSize
        return window
    }

    /// Rescues a restored height that is unusable, and otherwise leaves it alone.
    ///
    /// Only the two broken outcomes are corrected — a height too small to show anything, and one
    /// taller than the screen. A height the user chose is kept even when it is larger than this
    /// controller's own default, which an earlier version got wrong: clamping down to the default
    /// silently undid every deliberate resize on the next launch.
    private static func clampToUsableHeight(_ window: NSWindow) {
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let tallest = max(minimumContentSize.height, available - 40)
        let height = window.contentLayoutRect.height
        let width = max(window.frame.width, minimumContentSize.width)

        if height < minimumContentSize.height {
            window.setContentSize(
                NSSize(width: width, height: min(defaultContentSize.height, tallest)))
        } else if height > tallest {
            window.setContentSize(NSSize(width: width, height: tallest))
        }
    }

    @ViewBuilder private func rootView() -> some View {
        if let model {
            SettingsView().environment(model)
        } else {
            // The pane reads the model optionally, so it still renders — it just shows no live
            // usage-hours preview.
            SettingsView()
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Back to no Dock icon. Deferred because the policy change fights the close animation if
        // applied synchronously, which leaves a Dock icon behind after the window is gone.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Stranded frames

    /// Recentres a window whose remembered frame lies off every attached screen.
    ///
    /// The frame is persisted, so a frame saved on a display that is no longer connected strands
    /// the window permanently — reopening restores the same unreachable frame. Measured against the
    /// union of all screens so a window legitimately placed on a secondary display is left alone,
    /// and requiring half the window on screen rather than any overlap, because a visible sliver is
    /// not something you can find with the mouse.
    static func recentreIfStranded(_ window: NSWindow) {
        let visible = NSScreen.screens.map(\.visibleFrame)
        guard !visible.isEmpty else { return }

        let area = window.frame.width * window.frame.height
        guard area > 0 else { return }

        let onScreen = visible.reduce(0.0) { running, frame in
            let overlap = frame.intersection(window.frame)
            return overlap.isNull ? running : running + overlap.width * overlap.height
        }
        guard onScreen / area < 0.5 else { return }

        window.center()
    }
}
