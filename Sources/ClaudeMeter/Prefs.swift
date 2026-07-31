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
    /// `Bool`. Default false — the weekly chart is the slower-moving of the two, so it stays
    /// closed until asked for.
    public static let expandedWeekly = "expandedWeekly"
    /// `Bool`. Default false.
    public static let expandedSessions = "expandedSessions"
    /// `Bool`. Default false.
    public static let expandedDaily = "expandedDaily"
    /// `Bool`. Default false — the hour-of-day profile is a slow-moving shape, worth looking at
    /// occasionally rather than watching.
    public static let expandedHours = "expandedHours"

    /// `Bool`. Default false. Today's four tiles are a summary of the day, not the live reading
    /// the panel gets opened for — that is the two meters, which never collapse. The three stats
    /// groups run to around 250pt together on a panel that has to fit under the menu bar, and
    /// shipping them open would mean the panel only gets smaller after three clicks.
    public static let expandedToday = "expandedToday"
    /// `Bool`. Default false — a lifetime cache-hit ratio moves so slowly that a reader who saw it
    /// last week has seen this week's value.
    public static let expandedAllRecorded = "expandedAllRecorded"
    /// `Bool`. Default false. This is the group with the best claim to opening by itself, since it
    /// answers the one question the meters above it cannot — how much work is left, rather than
    /// what percentage is gone. It loses anyway on a first run, which is the only run a default
    /// decides: headroom needs a calibration built from several intervals of history, so on a
    /// fresh install the group renders nothing at all and opening it by default shows an empty
    /// heading.
    public static let expandedHeadroom = "expandedHeadroom"

    /// `Bool`. Default false. Not a setting anyone chooses: it is the two-column decision the
    /// panel measured its way to last time, kept so it opens in the shape it closed in. The
    /// measurement it comes from does not exist until after the first layout pass, so without a
    /// seed a two-column panel would open narrow and widen in front of the user every time.
    public static let panelWide = "panelWide"

    /// `Double`, seconds. The cadence the app has *learned*, not the one the user asked for —
    /// persisted so a rate limit discovered in one session is still respected after a relaunch.
    public static let pollIntervalSeconds = "pollIntervalSeconds"

    /// `Int`, seconds. The cadence the user asked for, from `pollIntervalChoices`. A target rather
    /// than a guarantee: a 429 can still widen the interval past it, and the app works back down
    /// to it. Default 180.
    public static let preferredPollIntervalSeconds = "preferredPollIntervalSeconds"

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
        public static let expandedWeekly = false
        public static let expandedSessions = false
        public static let expandedDaily = false
        public static let expandedHours = false
        public static let expandedToday = false
        public static let expandedAllRecorded = false
        public static let expandedHeadroom = false
        public static let panelWide = false
        public static let preferredPollIntervalSeconds = 180
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

    /// The cadences the Refresh picker offers, in seconds.
    ///
    /// 90 seconds is the fastest on offer because it is the fastest the app has ever polled: the
    /// endpoint's budget is per account and shared with Claude Code itself, and freshness bought
    /// with refusals is not freshness — a 429 widens the interval to several minutes, which is
    /// slower than any setting here. The top of the range is the same ceiling the backoff obeys, so
    /// the picker spans exactly the range the app already operated in.
    public static let pollIntervalChoices = [90, 120, 180, 300, 600, 900]

    /// The learned poll cadence, clamped into the range the model allows. A value written by an
    /// older build, a corrupted domain, or a hand-edited plist cannot make the app poll in a hot
    /// loop or stop polling altogether.
    public static func learnedPollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.double(forKey: pollIntervalSeconds)
        guard stored.isFinite, stored > 0 else { return defaultPollInterval }
        return min(max(stored, minimumPollInterval), maximumPollInterval)
    }

    public static func setLearnedPollInterval(
        _ seconds: TimeInterval, in defaults: UserDefaults = .standard
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        defaults.set(
            min(max(seconds, minimumPollInterval), maximumPollInterval),
            forKey: pollIntervalSeconds)
    }

    /// What to poll at now: the pace the user asked for, or a wider one the app learned from a
    /// refusal, whichever is slower. Both halves matter — a backoff outlives a relaunch, and a
    /// preference set faster than one does not entitle the app to ignore it.
    public static func effectivePollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        max(Current.preferredPollInterval(defaults), learnedPollInterval(defaults))
    }

    /// The nearest cadence the picker actually offers. A stored value from an older build or a
    /// hand-edited plist would otherwise select none of them and leave the control blank.
    public static func nearestPollIntervalChoice(to seconds: Int) -> Int {
        pollIntervalChoices.min { abs($0 - seconds) < abs($1 - seconds) }
            ?? Default.preferredPollIntervalSeconds
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
            expandedWeekly: Default.expandedWeekly,
            expandedSessions: Default.expandedSessions,
            expandedDaily: Default.expandedDaily,
            expandedHours: Default.expandedHours,
            expandedToday: Default.expandedToday,
            expandedAllRecorded: Default.expandedAllRecorded,
            expandedHeadroom: Default.expandedHeadroom,
            panelWide: Default.panelWide,
            preferredPollIntervalSeconds: Default.preferredPollIntervalSeconds,
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

        /// The cadence the user asked for. Snapped to the offered choices as well as clamped,
        /// because the picker binds to exactly these values.
        public static func preferredPollInterval(
            _ defaults: UserDefaults = .standard
        ) -> TimeInterval {
            let raw = defaults.object(forKey: Prefs.preferredPollIntervalSeconds) as? Int
                ?? Default.preferredPollIntervalSeconds
            return TimeInterval(nearestPollIntervalChoice(to: raw))
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
