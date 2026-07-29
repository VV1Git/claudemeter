import AppKit
import Combine
import SwiftUI
import UsageCore

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        // Charts and DisclosureGroups cannot live in a plain NSMenu, so the panel needs
        // the window style.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// Owns the `AppModel` so polling begins at launch instead of on the first panel open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist already sets LSUIElement; this also keeps an unbundled `swift run`
        // out of the Dock and the app switcher.
        NSApp.setActivationPolicy(.accessory)
        // Seeds the registration domain before anything reads it, so the model's direct
        // `UserDefaults` reads and the views' `@AppStorage` defaults cannot disagree.
        Prefs.registerDefaults()
        model.start()
    }
}

/// The always-visible menu bar item: rasterised ring plus the text for the chosen format.
/// Always the 5-hour window — never the most-constrained one.
private struct MenuBarLabel: View {
    let model: AppModel

    @AppStorage(Prefs.menuBarFormat) private var formatRaw = Prefs.Default.menuBarFormat.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var now = Date()

    /// The countdown variant has to advance between polls, and a failed poll can back off for
    /// up to 300s. Each tick also re-asks `MenuBarIcon` for its image, which is what eventually
    /// picks up a system accent change — nothing pushes one.
    @MainActor private static let ticker = Timer
        .publish(every: 30, tolerance: 5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        // Reading colorScheme is what invalidates this label when the menu bar appearance
        // flips, so the ring is re-rasterised for the new appearance. It is read rather than
        // applied as an `.id`, which would re-create the label and its ticker subscription
        // instead of just redrawing it.
        _ = colorScheme

        let window = model.snapshot?.fiveHour
        let projection = model.fiveHourProjection
        let text = MenuBarLabelText.text(
            format: format,
            percent: window?.utilization,
            projectedAtReset: projection?.projectedAtReset,
            resetsAt: window?.resetsAt,
            now: now
        )

        return HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(
                percent: window?.utilization,
                severity: model.snapshot?.severity(for: .fiveHour) ?? .normal,
                showsCapDot: projection?.willCapEarly ?? false
            ))
            .renderingMode(.original)

            if !text.isEmpty {
                Text(text).monospacedDigit()
            }
        }
        .onReceive(Self.ticker) { now = $0 }
    }

    private var format: MenuBarFormat {
        MenuBarFormat(rawValue: formatRaw) ?? Prefs.Default.menuBarFormat
    }
}
