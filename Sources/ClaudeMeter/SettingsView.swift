import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import UsageCore

/// The `Settings` scene. Every value here is `@AppStorage`-backed through `Prefs`; `UsageCore`
/// stays pure, so these are read at the call site and passed into it as parameters.
@MainActor
struct SettingsView: View {
    /// Defaults come from `Prefs.Default` rather than repeated literals: a view whose idea of
    /// "off" differs from the model's is invisible from the outside.
    @AppStorage(Prefs.menuBarFormat) private var menuBarFormat = Prefs.Default.menuBarFormat
        .rawValue
    @AppStorage(Prefs.activeGapMinutes) private var activeGapMinutes = Prefs.Default
        .activeGapMinutes
    @AppStorage(Prefs.notificationsEnabled) private var notificationsEnabled = Prefs.Default
        .notificationsEnabled
    @AppStorage(Prefs.notifyThresholdPercent) private var notifyThresholdPercent = Prefs.Default
        .notifyThresholdPercent

    /// Read optionally: the settings window is a separate scene, and the pane must still render if
    /// the model was not injected into it.
    @Environment(AppModel.self) private var model: AppModel?

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    init() {}

    var body: some View {
        Form {
            menuBarSection
            usageHoursSection
            refreshSection
            alertsSection
            startupSection
            footerSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // An accessory app never activates itself, so without this the window opens behind other
        // windows, stays on whichever desktop it was last used on, or is restored off-screen.
        .presentsAsSettingsWindow()
        .task {
            notificationStatus = await Notifier.shared.authorizationStatus()
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Section {
            Picker(selection: $menuBarFormat) {
                ForEach(MenuBarFormat.allCases, id: \.rawValue) { format in
                    Text(verbatim: format.settingsLabel).tag(format.rawValue)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            note("The menu bar tracks the 5-hour limit. The weekly limit lives in the panel.")
        } header: {
            header("Menu bar")
        }
    }

    // MARK: - Usage hours

    private var usageHoursSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("Idle gap")
                Slider(value: gapMinutes, in: Self.gapRange, step: 1)
                Text(verbatim: "\(activeGapMinutes) min")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }

            LabeledContent("Wall-clock time") {
                Text(verbatim: wallClockText)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }

            note(gapExplanation)
        } header: {
            header("Usage hours")
        }
    }

    /// The slider works in `Double` while the pref is an `Int` minute count. Both bounds come from
    /// `Prefs` so the stored value can never sit outside the range the UI offers.
    private static let gapRange =
        Double(Prefs.activeGapMinutesRange.lowerBound)...Double(
            Prefs.activeGapMinutesRange.upperBound)

    /// Driving the slider through a binding rather than `onChange` keeps the write to defaults and
    /// the recompute in one place, and skips both while a drag stays inside the same minute.
    private var gapMinutes: Binding<Double> {
        Binding(
            get: { Double(activeGapMinutes) },
            set: { newValue in
                let minutes = min(
                    Prefs.activeGapMinutesRange.upperBound,
                    max(Prefs.activeGapMinutesRange.lowerBound, Int(newValue.rounded())))
                guard minutes != activeGapMinutes else { return }
                activeGapMinutes = minutes
                // Recomputes from the cached events, so this is instant and triggers no rescan.
                model?.recomputeAggregates()
            })
    }

    private var gapExplanation: String {
        let base = "A pause longer than this ends an active stretch. Transcripts carry no "
            + "durations, so wall-clock time is inferred from message spacing."
        guard let hours = model?.usageHours, hours.agentTotal > 0 else { return base }
        return base + " Agent-hours (\(Self.durationText(hours.agentTotal))) ignore the gap — "
            + "sub-agents run from spawn to completion."
    }

    private var wallClockText: String {
        guard let hours = model?.usageHours else { return "—" }
        return Self.durationText(hours.wallClock)
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        Section {
            Toggle("Notify me when a limit is running out", isOn: $notificationsEnabled)
                .onChange(of: notificationsEnabled) { notificationsToggled() }

            Stepper(value: $notifyThresholdPercent, in: Prefs.notifyThresholdRange, step: 5) {
                Text(verbatim: "Alert at \(notifyThresholdPercent)% of a window")
                    .monospacedDigit()
            }
            .disabled(!notificationsEnabled)
            // A fired key identifies a window, not a threshold, so a new threshold has to be
            // allowed to alert on a window that already notified under the old one.
            .onChange(of: notifyThresholdPercent) { Notifier.shared.clearFiredKeys() }

            // Not gated on the toggle: a refused request switches the toggle straight back off,
            // so gating would hide the only explanation the user ever gets.
            if notificationStatus == .denied {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        verbatim: "macOS is blocking notifications for ClaudeMeter, so this "
                            + "stays off until you allow them.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings") { openNotificationSettings() }
                        .controlSize(.small)
                }
            }

            note(
                "Alerts fire when a window crosses the threshold or is on pace to run out before "
                    + "it resets — once per window, not once per poll. Colour in the panel is "
                    + "always on. Nothing is requested from the system until you switch this on.")
        } header: {
            header("Alerts")
        }
    }

    private func notificationsToggled() {
        guard notificationsEnabled else { return }
        Task {
            // The only authorisation request in the app, so a default install never prompts.
            let granted = await Notifier.shared.requestAuthorization()
            notificationStatus = await Notifier.shared.authorizationStatus()
            if !granted { notificationsEnabled = false }
        }
    }

    /// System Settings renamed the notifications pane; the legacy prefpane identifier is kept as a
    /// fallback so the button still opens something if the modern one is refused.
    private func openNotificationSettings() {
        let panes = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for pane in panes {
            guard let url = URL(string: pane) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Startup

    /// Read-only on purpose. The cadence is not a preference — it is what the app has found the
    /// endpoint will tolerate. Shown because a reading a few minutes old otherwise looks like a
    /// stuck app rather than a deliberate choice.
    private var refreshSection: some View {
        Section {
            LabeledContent("Checking limits every") {
                Text(intervalLabel).monospacedDigit()
            }
            Text(verbatim: refreshExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Refresh")
        }
    }

    private var refreshExplanation: String {
        if model?.isThrottled == true {
            return "Slowed down after the usage endpoint rate-limited this account. It speeds back "
                + "up on its own once requests are being accepted again. The statistics from your "
                + "transcripts refresh independently of this."
        }
        return "Tuned automatically. The usage endpoint is rate-limited per account and shared "
            + "with Claude Code itself, so ClaudeMeter backs off when it is refused and edges back "
            + "up when it is not."
    }

    private var intervalLabel: String {
        guard let interval = model?.pollInterval else { return "—" }
        let seconds = Int(interval.rounded())
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    private var startupSection: some View {
        Section {
            Toggle("Launch ClaudeMeter at login", isOn: launchAtLogin)

            if loginItemStatus == .requiresApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS needs ClaudeMeter approved in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }

            if let loginItemError {
                Text(verbatim: loginItemError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if loginItemStatus == .notFound {
                note("Available once ClaudeMeter is running from a built .app bundle.")
            }
        } header: {
            header("Startup")
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                }
                loginItemStatus = SMAppService.mainApp.status
            })
    }

    // MARK: - Footer

    private var footerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    verbatim: "Settings live in this app's user defaults. Poll history, the "
                        + "cached snapshot and the event cache are files in \(Self.supportPath).")
                Text(
                    verbatim: "The OAuth token is read from the Keychain on every poll and is "
                        + "never written, cached, or sent anywhere but api.anthropic.com.")
                if let factor = model?.inflationFactor, factor > 1.01 {
                    Text(
                        verbatim: "Transcript rows repeat \(Self.factorText(factor)) over; each "
                            + "response is counted once.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared bits

    private func header(_ title: String) -> some View {
        Text(verbatim: title.uppercased())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static var supportPath: String {
        (Paths.supportDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private static func factorText(_ factor: Double) -> String {
        String(format: "%.2f×", factor)
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours == 0 ? "\(minutes)m" : "\(hours)h \(minutes)m"
    }
}
