import Foundation
import UsageCore

// MARK: - Keys

/// Every `UserDefaults` / `@AppStorage` key the app uses, and the default that goes with it.
///
/// The literals live here and nowhere else. A mistyped key does not look like a bug from the
/// outside — the setting simply stops driving the behaviour it names, and both halves keep
/// working in isolation — so there are no inline key strings anywhere in the app target.
public enum Prefs {
    /// `MenuBarFormat.rawValue`. Default `.percentAndPace`.
    public static let menuBarFormat = "menuBarFormat"
    /// `Int` minutes of idle time that ends an active stretch. Default 10.
    public static let activeGapMinutes = "activeGapMinutes"
    /// `Bool`. Default false, so a default install never asks for notification permission.
    public static let notificationsEnabled = "notificationsEnabled"
    /// `Int` percentage. Default 90.
    public static let notifyThresholdPercent = "notifyThresholdPercent"
    /// JSON-encoded `[String]` of window instances already notified about.
    public static let firedNotificationKeys = "firedNotificationKeys"
    /// `Bool`. Default true — the 5-hour chart is the one section that opens by itself.
    public static let expandedFiveHour = "expandedFiveHour"
    /// `Bool`. Default false.
    public static let expandedSessions = "expandedSessions"
    /// `Bool`. Default false.
    public static let expandedDaily = "expandedDaily"

    /// `Double`, seconds. The cadence the app has learned, not a user setting — persisted so a
    /// rate limit discovered in one session is still respected after a relaunch.
    public static let pollIntervalSeconds = "pollIntervalSeconds"

    // MARK: - Defaults

    /// The value every `@AppStorage` declaration of the matching key must use as its default.
    /// Referencing these instead of repeating literals is what keeps a view's idea of "off"
    /// identical to the model's.
    public enum Default {
        public static let menuBarFormat: MenuBarFormat = .percentAndPace
        public static let activeGapMinutes = 10
        public static let notificationsEnabled = false
        public static let notifyThresholdPercent = 90
        public static let expandedFiveHour = true
        public static let expandedSessions = false
        public static let expandedDaily = false
    }

    /// Bounds of the active-gap slider. Below 5 minutes a normal pause between prompts
    /// fragments one sitting into many; above 30 an evening off reads as continuous work.
    public static let activeGapMinutesRange = 5...30

    /// Bounds of the notification threshold stepper.
    public static let notifyThresholdRange = 50...99

    /// Bounds and starting point of the learned poll cadence, in seconds.
    ///
    /// They live here rather than on `AppModel` because clamping happens on the persistence path,
    /// which is not main-actor confined — reaching into `AppModel`'s `@MainActor` statics from here
    /// is an error under the Swift 6 language mode.
    public static let defaultPollInterval: TimeInterval = 180
    public static let minimumPollInterval: TimeInterval = 90
    public static let maximumPollInterval: TimeInterval = 15 * 60

    /// The learned poll cadence, clamped into the range the model allows. A value written by an
    /// older build, a corrupted domain, or a hand-edited plist cannot make the app poll in a hot
    /// loop or stop polling altogether.
    public static func pollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.double(forKey: pollIntervalSeconds)
        guard stored.isFinite, stored > 0 else { return defaultPollInterval }
        return min(max(stored, minimumPollInterval), maximumPollInterval)
    }

    public static func setPollInterval(
        _ seconds: TimeInterval, in defaults: UserDefaults = .standard
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        defaults.set(
            min(max(seconds, minimumPollInterval), maximumPollInterval),
            forKey: pollIntervalSeconds)
    }

    /// Seeds the registration domain so code that reads `UserDefaults` directly (the model,
    /// which has no `@AppStorage`) sees the same defaults a view would.
    public static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            menuBarFormat: Default.menuBarFormat.rawValue,
            activeGapMinutes: Default.activeGapMinutes,
            notificationsEnabled: Default.notificationsEnabled,
            notifyThresholdPercent: Default.notifyThresholdPercent,
            expandedFiveHour: Default.expandedFiveHour,
            expandedSessions: Default.expandedSessions,
            expandedDaily: Default.expandedDaily,
        ])
    }

    // MARK: - Typed reads

    /// Current values, for the code that has no `@AppStorage` to read through. Every accessor
    /// falls back to `Prefs.Default` and clamps to the range the UI offers, so a hand-edited
    /// plist or a stale key cannot produce a setting the app has no sane behaviour for.
    public enum Current {
        public static func menuBarFormat(_ defaults: UserDefaults = .standard) -> MenuBarFormat {
            guard let raw = defaults.string(forKey: Prefs.menuBarFormat),
                  let format = MenuBarFormat(rawValue: raw)
            else { return Default.menuBarFormat }
            return format
        }

        public static func activeGapMinutes(_ defaults: UserDefaults = .standard) -> Int {
            let raw = defaults.object(forKey: Prefs.activeGapMinutes) as? Int
                ?? Default.activeGapMinutes
            return min(max(raw, activeGapMinutesRange.lowerBound), activeGapMinutesRange.upperBound)
        }

        /// The same setting as `activeGapMinutes`, in the seconds `Aggregates` takes.
        public static func activeGap(_ defaults: UserDefaults = .standard) -> TimeInterval {
            TimeInterval(activeGapMinutes(defaults)) * 60
        }

        public static func notificationsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
            defaults.object(forKey: Prefs.notificationsEnabled) as? Bool
                ?? Default.notificationsEnabled
        }

        public static func notifyThresholdPercent(_ defaults: UserDefaults = .standard) -> Int {
            let raw = defaults.object(forKey: Prefs.notifyThresholdPercent) as? Int
                ?? Default.notifyThresholdPercent
            return min(max(raw, notifyThresholdRange.lowerBound), notifyThresholdRange.upperBound)
        }

        public static func firedNotificationKeys(_ defaults: UserDefaults = .standard) -> Set<String> {
            FiredKeys.decode(defaults.string(forKey: Prefs.firedNotificationKeys) ?? "")
        }

        public static func setFiredNotificationKeys(
            _ keys: Set<String>, in defaults: UserDefaults = .standard
        ) {
            defaults.set(FiredKeys.encode(keys), forKey: Prefs.firedNotificationKeys)
        }
    }

    // MARK: - Fired notification keys

    /// `firedNotificationKeys` is a JSON string rather than a real array because `@AppStorage`
    /// cannot bind a collection. Both halves of the app must agree on the encoding, so it lives
    /// here next to the key.
    public enum FiredKeys {
        /// Anything unreadable decodes to empty: losing the fired set costs at most one
        /// duplicate notification, while throwing would break the alert path entirely.
        public static func decode(_ json: String) -> Set<String> {
            guard let data = json.data(using: .utf8),
                  let keys = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(keys)
        }

        /// Sorted before encoding so the stored string is stable for an unchanged set and
        /// `@AppStorage` does not report a write that changed nothing.
        public static func encode(_ keys: Set<String>) -> String {
            guard let data = try? JSONEncoder().encode(keys.sorted()),
                  let json = String(data: data, encoding: .utf8)
            else { return "[]" }
            return json
        }
    }
}
