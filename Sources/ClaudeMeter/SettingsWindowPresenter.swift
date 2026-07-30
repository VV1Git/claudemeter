import AppKit
import SwiftUI

// MARK: - Settings window presentation

/// Makes the `Settings` scene behave for a menu bar app.
///
/// The app runs under `.accessory` activation policy so it has no Dock icon, and that is exactly
/// what breaks the settings window: an accessory app is never activated on its own behalf, so
/// `SettingsLink` opens a window that nothing brings forward. Three distinct symptoms come out of
/// it, and all three are fixed here rather than in `SettingsView`, which should stay a plain form:
///
/// 1. **Nothing appears.** The window did open, ordered behind whatever was in front. It has to be
///    explicitly activated and ordered front.
/// 2. **It appears on another desktop.** Without `.moveToActiveSpace` the window stays on the Space
///    it was last used on, so on any other Space it is invisible — or macOS yanks you across to it.
/// 3. **Nothing appears, permanently.** The frame is restored from `UserDefaults`, so a frame saved
///    on a display that is no longer attached puts the window off every current screen. Reopening
///    cannot fix that, because the bad frame is what gets restored each time.
struct SettingsWindowPresenter: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // The window is not in the hierarchy during `makeNSView`, so the work is deferred a turn.
        DispatchQueue.main.async { present(probe.window) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Also on update: reopening the settings scene reuses the same window, and a second open
        // gets no fresh `makeNSView`.
        DispatchQueue.main.async { present(nsView.window) }
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }

        window.collectionBehavior.insert(.moveToActiveSpace)
        Self.moveOnScreenIfStranded(window)

        // `ignoringOtherApps` is required, not cosmetic: an accessory app asking politely is
        // ignored while another app is frontmost, which is the usual case — the user just clicked
        // a menu bar item belonging to something else.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Recentres the window when its restored frame lies off every attached screen. Compares
    /// against the union of the screens rather than `NSScreen.main`, so a legitimately placed
    /// window on a secondary display is left where the user put it.
    static func moveOnScreenIfStranded(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let visible = screens.map(\.visibleFrame)

        // A sliver on screen is not good enough to find with the mouse — require enough of the
        // window to be reachable, or treat it as stranded.
        let onScreenArea = visible.reduce(0.0) { area, frame in
            let overlap = frame.intersection(window.frame)
            return overlap.isNull ? area : area + overlap.width * overlap.height
        }
        let windowArea = window.frame.width * window.frame.height
        guard windowArea > 0 else { return }
        guard onScreenArea / windowArea < 0.5 else { return }

        window.center()
    }
}

extension View {
    /// Attach to the root of the `Settings` scene.
    func presentsAsSettingsWindow() -> some View {
        background(SettingsWindowPresenter().frame(width: 0, height: 0))
    }
}
