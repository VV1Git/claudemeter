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
    @AppStorage(Prefs.preferredPollIntervalSeconds) private var preferredPollIntervalSeconds = Prefs
        .Default.preferredPollIntervalSeconds
    /// Read optionally: the settings window is a separate scene, and the pane must still render if
    /// the model was not injected into it.
    @Environment(AppModel.self) private var model: AppModel?

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Deliberately `@State` and never `@AppStorage`: this is a bearer token, and the only place
    /// it is written down is the Keychain item the Use button puts it in.
    @State private var dedicatedToken = ""
    @State private var tokenError: String?
    @State private var isAdopting = false
    /// The `code#state` string from the callback page, on the fallback route where no loopback
    /// port could be opened. Same reasoning as `dedicatedToken`: it buys a credential, so it
    /// lives no longer than the sign-in that produced it.
    @State private var pastedCode = ""
    /// Held so Cancel can actually stop the wait — cancelling this task is what unblocks the
    /// loopback listener.
    @State private var signInTask: Task<Void, Never>?

    init() {}

    var body: some View {
        Form {
            menuBarSection
            usageHoursSection
            refreshSection
            credentialsSection
            alertsSection
            startupSection
            footerSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
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

    // MARK: - Refresh

    /// The pace to aim for, not a guarantee — the backoff can still widen the interval past it, and
    /// the second row says so when it has. Without that row the setting would look ignored, which
    /// is the same failure the old read-only display existed to avoid.
    private var refreshSection: some View {
        Section {
            Picker(selection: preferredPollInterval) {
                ForEach(Prefs.pollIntervalChoices, id: \.self) { seconds in
                    Text(verbatim: Self.intervalText(TimeInterval(seconds))).tag(seconds)
                }
            } label: {
                Text("Check limits every")
            }

            if model?.isThrottled == true {
                LabeledContent("Currently") {
                    Text(verbatim: intervalLabel).monospacedDigit()
                }
            }

            Text(verbatim: refreshExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            header("Refresh")
        }
    }

    /// Writes the preference and re-times the poll loop in one place, the same shape as the
    /// idle-gap slider. The getter reads back through `Prefs` so a value no longer on offer selects
    /// the nearest one rather than leaving the picker blank.
    private var preferredPollInterval: Binding<Int> {
        Binding(
            get: { Int(Prefs.Current.preferredPollInterval()) },
            set: { seconds in
                guard seconds != preferredPollIntervalSeconds else { return }
                preferredPollIntervalSeconds = seconds
                model?.applyPreferredPollInterval()
            })
    }

    private var refreshExplanation: String {
        if model?.isThrottled == true {
            return "The usage endpoint rate-limited this account, so ClaudeMeter is polling slower "
                + "than you asked for. It works back towards your setting on its own once requests "
                + "are being accepted again. The statistics from your transcripts refresh "
                + "independently of this."
        }
        return "The pace to aim for rather than a promise. This endpoint is rate-limited per "
            + "account and shares that budget with Claude Code itself, so ClaudeMeter backs off "
            + "when it is refused and works back up to your setting — and a refusal costs minutes, "
            + "which is why the fastest setting here is not the freshest by default."
    }

    private var intervalLabel: String {
        guard let interval = model?.pollInterval else { return "—" }
        return Self.intervalText(interval)
    }

    /// Whole minutes read as minutes; anything under two is left in seconds, so the fastest cadence
    /// on offer is `90 s` rather than `1 min 30 s`.
    private static func intervalText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 120 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    // MARK: - Credentials

    /// How ClaudeMeter gets a token, and the one thing the user can do to stop macOS asking.
    ///
    /// There used to be a switch here offering to let ClaudeMeter renew Claude Code's token. It
    /// is gone, and not because it was hard to explain: it could not be made safe. Renewing means
    /// spending the CLI's refresh token, which the endpoint rotates, so the CLI's copy dies the
    /// moment it is spent — and the only way to hand the replacement over is to write the shared
    /// Keychain item, which macOS answers by rebuilding that item's list of permitted programs
    /// around ClaudeMeter alone. Measured on this machine: both the modern and the legacy write
    /// API collapse the list to the writer. So the switch chose between signing you out of Claude
    /// Code and locking Claude Code out of its own credential, and neither is a setting.
    ///
    /// What is offered instead is a token of ClaudeMeter's own, which sidesteps the whole
    /// business: it lives in an item this app creates and nothing else writes, so no list is ever
    /// reset and no dialog is ever raised.
    private var credentialsSection: some View {
        Section {
            if model?.hasDedicatedToken == true {
                LabeledContent("Token") {
                    Text(verbatim: "ClaudeMeter\u{2019}s own")
                        .foregroundStyle(.secondary)
                }
                Button("Forget It and Use Claude Code\u{2019}s") {
                    Task { await model?.forgetDedicatedToken() }
                }
                .controlSize(.small)
                note(
                    "ClaudeMeter is using its own token, so it never reads Claude Code\u{2019}s "
                        + "credential and macOS never asks you to authorize anything.")
            } else {
                signInControls
                manualTokenControls
            }

            if let tokenError {
                Text(verbatim: tokenError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model?.cliLockedOut == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        verbatim: repairCommand == nil
                            ? "Claude Code is currently locked out of the Keychain item. "
                                + "ClaudeMeter could not work out the exact command for this "
                                + "machine \u{2014} run scripts/repair-keychain-partition-list.sh from "
                                + "the ClaudeMeter source instead."
                            : "Claude Code is currently locked out of the Keychain item. Copy "
                                + "the repair command and run it in a terminal. ClaudeMeter no "
                                + "longer writes that item, so this should not come back."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    // Offered only when this build's own identity is known: the command replaces
                    // the item's list of permitted programs, so one naming the wrong identity
                    // would lock ClaudeMeter out in the act of letting Claude Code back in.
                    if let command = repairCommand {
                        Button("Copy Repair Command") { copyRepairCommand(command) }
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            header("Credentials")
        }
    }

    /// The one-click route: a browser sign-in that hands back a credential ClaudeMeter owns and
    /// can renew, so the Keychain prompts stop for good without a trip to a terminal.
    @ViewBuilder private var signInControls: some View {
        switch model?.signInStage ?? .idle {
        case .idle:
            Button("Sign In with Claude\u{2026}") { beginSignIn() }
            note(
                "The way to stop the Keychain prompts for good. Your browser opens, you "
                    + "authorize once, and ClaudeMeter gets a credential of its own \u{2014} Claude "
                    + "Code\u{2019}s is left untouched, so neither one can evict the other again.")

        case .waitingForBrowser:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: "Waiting for your browser\u{2026}")
                    .foregroundStyle(.secondary)
                Button("Cancel") { cancelSignIn() }
                    .controlSize(.small)
            }
            note("Authorize ClaudeMeter in the tab that just opened. It finishes on its own.")

        case .awaitingPastedCode:
            // Only reached when no loopback port could be opened, so the browser had to be sent
            // to the page that displays the code instead of one that comes back by itself.
            HStack(spacing: 8) {
                SecureField("Paste the code from the browser", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                Button("Finish") { finishSignIn() }
                    .disabled(
                        pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isAdopting)
                Button("Cancel") { cancelSignIn() }
                    .controlSize(.small)
            }
            note(
                "ClaudeMeter could not open a local port for the browser to return to, so the "
                    + "code has to come back by hand. Copy what the page shows and paste it here.")
        }
    }

    /// The older route, kept because it is the one that works when the browser flow cannot be
    /// completed at all — a machine with no default browser, or an account that has to sign in
    /// somewhere else. Collapsed by default so it does not compete with the button above.
    @ViewBuilder private var manualTokenControls: some View {
        DisclosureGroup("Use a token from `claude setup-token` instead") {
            HStack(spacing: 8) {
                SecureField("sk-ant-oat01-\u{2026}", text: $dedicatedToken)
                    .textFieldStyle(.roundedBorder)
                Button("Use") { adoptToken() }
                    .disabled(
                        dedicatedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isAdopting)
            }
            note(
                "Run `claude setup-token` in a terminal and paste the token here. It works, but "
                    + "it carries nothing to renew itself with, so it has to be redone when it "
                    + "expires \u{2014} signing in above does not.")
        }
        .font(.callout)
    }

    private var repairCommand: String? { model?.partitionRepairCommand }

    private func copyRepairCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Opens the browser and waits for the code to come back.
    private func beginSignIn() {
        tokenError = nil
        pastedCode = ""
        signInTask?.cancel()
        signInTask = Task {
            guard let model else {
                tokenError = "ClaudeMeter is still starting up. Try again in a moment."
                return
            }
            tokenError = await model.signIn()
            signInTask = nil
        }
    }

    /// Finishes the fallback route with the code the user copied out of the browser.
    private func finishSignIn() {
        let code = pastedCode
        isAdopting = true
        tokenError = nil
        Task {
            guard let model else {
                isAdopting = false
                tokenError = "ClaudeMeter is still starting up. Try again in a moment."
                return
            }
            let failure = await model.completeSignIn(withPastedCode: code)
            isAdopting = false
            tokenError = failure
            if failure == nil { pastedCode = "" }
        }
    }

    /// Cancelling the task is what unblocks a loopback wait; the model call clears the stage so
    /// the button comes back even on the route where there is no task to cancel.
    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        pastedCode = ""
        tokenError = nil
        model?.cancelSignIn()
    }

    /// Spends the pasted token on a real request before accepting it, so a token that does not
    /// work for this endpoint is reported while the user is still looking at the field.
    private func adoptToken() {
        let token = dedicatedToken
        isAdopting = true
        tokenError = nil
        Task {
            // `model` is optional because this pane must still render when the scene was built
            // without one. Optional-chaining the call would then evaluate to `nil`, which is also
            // what success looks like — so the field would clear and the user would believe a
            // token had been saved that never left this view.
            guard let model else {
                isAdopting = false
                tokenError = "ClaudeMeter is still starting up. Try again in a moment."
                return
            }
            let failure = await model.adoptDedicatedToken(token)
            isAdopting = false
            tokenError = failure
            if failure == nil { dedicatedToken = "" }
        }
    }

    // MARK: - Startup

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
                    verbatim: "The OAuth token is never sent anywhere but api.anthropic.com, and "
                        + "Claude Code's credential is only ever read \u{2014} ClaudeMeter never "
                        + "writes it. The token is held in memory between polls rather than "
                        + "re-read each time.")
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
