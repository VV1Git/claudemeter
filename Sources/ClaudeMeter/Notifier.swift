import Foundation
import UserNotifications
import UsageCore

/// Threshold and pace alerts for the two limit windows.
///
/// Authorisation is requested only from `requestAuthorization()`, and only the settings toggle
/// calls that, so a default install — notifications off — never raises a system permission prompt.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Mirrors `Prefs.notifyThresholdPercent`'s documented default.
    static let defaultThresholdPercent = Prefs.Default.notifyThresholdPercent

    /// Cooldown used when a window reports no reset time, or reports one that has already passed.
    /// Without a future reset to suppress on there is no window identity either, so the same
    /// window would alert on every poll.
    private static let unknownResetCooldown: TimeInterval = 24 * 3600

    private struct Alert {
        let title: String
        let body: String
    }

    private let defaults = UserDefaults.standard
    private var didInstallDelegate = false

    private override init() { super.init() }

    // MARK: - Preferences

    var isEnabled: Bool { Prefs.Current.notificationsEnabled(defaults) }

    /// Read through `Prefs.Current`, which applies the documented default and clamps to the range
    /// the settings stepper offers. Reading `UserDefaults` directly would accept anything that is
    /// in the plist — an unset key reads back as 0, and 0 alerts at any percentage at all.
    var thresholdPercent: Int { Prefs.Current.notifyThresholdPercent(defaults) }

    // MARK: - Authorisation

    /// The only call site is the settings toggle being switched on.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center = Self.center else { return false }
        installDelegate(on: center)
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Reads the current permission state. Does not prompt, so it is safe to call on every
    /// appearance of the settings pane.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center = Self.center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    // MARK: - Evaluation

    /// Called after a poll updates the projections. Posts at most one notification per window
    /// instance, however many polls that window survives.
    func evaluate(fiveHour: Projection?, sevenDay: Projection?, now: Date = Date()) {
        guard isEnabled, let center = Self.center else { return }
        installDelegate(on: center)

        let stored = Prefs.Current.firedNotificationKeys(defaults)
        // A key whose reset has passed can no longer be suppressing anything, so dropping it here
        // is both the prune and the "this is a new window" test. The set therefore holds at most
        // one key per window kind and cannot grow with the age of the install.
        var live = Self.unexpired(stored, now: now)

        for projection in [fiveHour, sevenDay].compactMap({ $0 }) {
            guard !Self.holdsKey(live, kind: projection.kind),
                let alert = alerts(for: projection, now: now).first
            else { continue }
            let key = Self.key(kind: projection.kind, stamp: stamp(for: projection, now: now))
            live.insert(key)
            post(alert, key: key, on: center)
        }

        // Covers both new alerts and the prune above, and leaves defaults untouched otherwise.
        if live != stored { Prefs.Current.setFiredNotificationKeys(live, in: defaults) }
    }

    /// Convenience for the poll loop, which owns both projections.
    func evaluate(_ model: AppModel, now: Date = Date()) {
        evaluate(fiveHour: model.fiveHourProjection, sevenDay: model.sevenDayProjection, now: now)
    }

    /// Forgets which windows have been alerted on. The settings pane calls this when the threshold
    /// changes: a key identifies a window, not a threshold, so lowering 95 → 80 has to be able to
    /// alert on a window that already notified under the old setting.
    func clearFiredKeys() {
        defaults.removeObject(forKey: Prefs.firedNotificationKeys)
    }

    // MARK: - Alert construction

    /// Most urgent first; only the first entry is ever posted, because a window instance gets one
    /// alert. Running out before the reset is the more actionable of the two, so it outranks the
    /// bare threshold crossing.
    private func alerts(for projection: Projection, now: Date) -> [Alert] {
        let label = projection.kind.longLabel
        let percent = Int(projection.currentPercent.rounded())
        var alerts: [Alert] = []

        if projection.willCapEarly, let cap = projection.timeToCap {
            let capIn = MenuBarLabelText.compactDuration(until: cap, now: now)
            let resetClause = projection.resetsAt.map {
                ", before the window resets in "
                    + MenuBarLabelText.compactDuration(until: $0, now: now)
            } ?? ""
            alerts.append(
                Alert(
                    title: "\(label) limit on pace to run out",
                    body: "At \(rateText(projection.percentPerHour)) you reach 100% in "
                        + "\(capIn)\(resetClause)."))
        }

        if percent >= thresholdPercent {
            let resetClause = projection.resetsAt.map {
                "Resets in " + MenuBarLabelText.compactDuration(until: $0, now: now) + "."
            } ?? "No reset time reported."
            alerts.append(Alert(title: "\(label) limit at \(percent)%", body: resetClause))
        }

        return alerts
    }

    private func rateText(_ percentPerHour: Double) -> String {
        let magnitude = abs(percentPerHour)
        let formatted = magnitude >= 10
            ? String(format: "%.0f", percentPerHour)
            : String(format: "%.1f", percentPerHour)
        return "~\(formatted) pts/hr"
    }

    // MARK: - Fired-key persistence

    /// Keyed by the window's reset time, because that is a limit window's only identity, and
    /// matched by *kind* against the stored stamp rather than by an exact stamp equality: the
    /// 5-hour window is rolling, so `resets_at` creeps forward as usage ages out (see
    /// `WindowKind.nominalDuration`). An exact match would mint a fresh key on every poll whose
    /// reported reset had moved by even a second, and post a banner every 60 seconds — the exact
    /// storm the fired set exists to prevent.
    ///
    /// The stored stamp is the reset the user was told about, so the suppression lapses precisely
    /// when that window is over and a genuinely new window can alert again.
    private static func key(kind: WindowKind, stamp: Date) -> String {
        "\(kind.rawValue)|\(Int(stamp.timeIntervalSince1970.rounded()))"
    }

    private static func parse(_ key: String) -> (kind: WindowKind, stamp: Double)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2, let kind = WindowKind(rawValue: String(parts[0])),
            let stamp = Double(parts[1])
        else { return nil }
        return (kind, stamp)
    }

    /// Keys whose window has not reset yet. Unparseable keys are dropped rather than kept, so a
    /// hand-edited or older-format value cannot suppress alerts forever.
    private static func unexpired(_ keys: Set<String>, now: Date) -> Set<String> {
        let nowSeconds = now.timeIntervalSince1970
        return keys.filter { key in
            guard let stamp = parse(key)?.stamp else { return false }
            return stamp > nowSeconds
        }
    }

    private static func holdsKey(_ keys: Set<String>, kind: WindowKind) -> Bool {
        keys.contains { parse($0)?.kind == kind }
    }

    /// The reset this alert is about. A window with no reset time — or one whose reported reset
    /// has already passed — gets a synthetic cooldown instead of a stamp in the past, which would
    /// expire immediately and re-alert on the next poll. An implausibly distant reset is capped at
    /// twice the window length so a corrupt payload cannot silence alerts indefinitely.
    private func stamp(for projection: Projection, now: Date) -> Date {
        guard let resetsAt = projection.resetsAt, resetsAt > now else {
            return now.addingTimeInterval(
                min(projection.kind.nominalDuration, Self.unknownResetCooldown))
        }
        return min(resetsAt, now.addingTimeInterval(projection.kind.nominalDuration * 2))
    }

    // MARK: - Delivery

    private func post(_ alert: Alert, key: String, on center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // The identifier is the fired key, so even a double evaluation collapses to one banner.
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        Task { try? await center.add(request) }
    }

    /// Opening the panel activates the app, and macOS suppresses banners for the active app unless
    /// a delegate asks for them — the alert would be swallowed exactly while the user is looking at
    /// their usage.
    private func installDelegate(on center: UNUserNotificationCenter) {
        guard !didInstallDelegate else { return }
        didInstallDelegate = true
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Center

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle identifier — the
    /// binary run straight out of `.build` rather than from the packaged `.app` — so every entry
    /// point degrades to a no-op there instead of crashing the app.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
