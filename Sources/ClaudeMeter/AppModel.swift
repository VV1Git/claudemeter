import AppKit
import Foundation
import Observation
import UsageCore

// MARK: - AppModel

/// Everything the UI observes, and the only place that talks to the network, the Keychain and
/// the filesystem.
///
/// `@MainActor` is a hard requirement rather than a convenience: `SampleStore` and
/// `TranscriptScanner` are plain classes with unsynchronised mutable state and no `Sendable`
/// conformance, so the single-actor confinement here is what makes them safe to use at all.
/// The one piece of work that cannot run on the main actor — the pass over the whole transcript
/// corpus — is detached, owns its own scanner, and hands back only value types (see `ScanWorker`).
@MainActor @Observable public final class AppModel {

    // MARK: Observed state

    public private(set) var snapshot: UsageSnapshot?
    public private(set) var fiveHourProjection: Projection?
    public private(set) var sevenDayProjection: Projection?
    public private(set) var health: DataHealth = .live
    public private(set) var sessions: [SessionStat] = []
    public private(set) var daily: [DailyStat] = []
    public private(set) var models: [ModelUsage] = []
    public private(set) var efforts: [EffortUsage] = []
    public private(set) var usageHours: UsageHours?
    public private(set) var samples: [Sample] = []
    public private(set) var isScanning = false
    /// True while a request is in flight, so the reload button can show that the press landed.
    /// Separate from `isScanning`: they are two different pieces of work with two different costs.
    public private(set) var isPolling = false
    public private(set) var lastUpdate: Date?
    /// Transcript rows read per distinct request — normally well above 1.0. Nil until a
    /// scan has completed; shown in settings to explain why these numbers are lower than a
    /// naive sum over the transcripts.
    public private(set) var inflationFactor: Double?
    /// Share of the input side served from cache, over every event held. 0 before the first scan.
    public private(set) var cacheHitRatio: Double = 0
    /// Share of weighted spend that went to sub-agents.
    public private(set) var sidechainShare: Double = 0
    /// Weighted spend by local hour of day.
    public private(set) var hourProfile: [HourBucket] = []
    /// Points-to-tokens exchange rate per window, and this cycle's pace against its own norm.
    public private(set) var fiveHourCalibration: LimitCalibration?
    public private(set) var sevenDayCalibration: LimitCalibration?
    public private(set) var cyclePace: CyclePace?
    /// Deduplicated events behind the aggregates, for the "counted N requests" line.
    public private(set) var eventCount = 0

    // MARK: Tuning

    /// Where a first run starts, before anything has been learned and before the user has said
    /// otherwise.
    ///
    /// Deliberately slower than the endpoint strictly needs. The budget is per account and shared
    /// with Claude Code itself, so the app cannot know how much of it is already spent; starting
    /// slow and earning speed costs a little freshness and avoids teaching the limiter that we are
    /// a problem. Four samples at this rate still clear `ProjectionEngine`'s 10-minute minimum.
    public static let defaultPollInterval = Prefs.defaultPollInterval
    /// Never poll faster than this, however well things are going and whatever is asked for — it is
    /// also the fastest cadence the Refresh picker offers.
    public static let minimumPollInterval = Prefs.minimumPollInterval
    /// Never slower than this, or the app stops being a live meter.
    public static let maximumPollInterval = Prefs.maximumPollInterval

    /// A 429 multiplies the interval by this and remembers it.
    private static let slowdownFactor: Double = 2.0
    /// Consecutive clean polls required before trying a slightly faster cadence.
    private static let successesBeforeSpeedup = 12
    /// How much of the interval is given back after that run of successes.
    ///
    /// Both directions are multiplicative — double on refusal, give back a fifth after a clean run —
    /// so it retreats fast and advances slowly, which is what keeps it from oscillating in and out of
    /// the limit. (Not additive-increase/multiplicative-decrease, despite the shape of the idea.)
    private static let speedupFactor: Double = 0.8

    /// How much life a token must have left to be used as-is. Wider than the slowest poll
    /// interval, so every poll finds a token that will still be valid when its request lands
    /// — the app never has to discover expiry by being refused. Wider still would mean
    /// refreshing sooner than Claude Code does and rotating tokens out from under it.
    private static let refreshLeadTime: TimeInterval = 5 * 60
    /// Attempts at writing a refreshed pair back to the shared Keychain item.
    private static let credentialWriteAttempts = 3
    private static let credentialWriteRetryDelay: TimeInterval = 0.1

    private static let maximumBackoff: TimeInterval = 300
    /// A `Retry-After` is honoured as sent, but not unboundedly: a header that asks for a day
    /// would otherwise park the app until it is relaunched.
    private static let maximumHonouredRetryAfter: TimeInterval = 3600
    /// Two 7-day windows' worth of headroom, so a weekly projection always has a full window
    /// of history behind it even right after a reset.
    private static let sampleRetention: TimeInterval = 8 * 24 * 3600
    /// Rescan cadence. Passes after the first are incremental — files already at their stored
    /// offset are not reopened — so this costs close to nothing and keeps sessions current.
    private static let rescanInterval: TimeInterval = 5 * 60
    private static let dailyHistoryDays = 30
    /// Trailing days behind the hour-of-day profile. Long enough that one unusual night does
    /// not define the shape, short enough that a change of working hours shows up.
    private static let hourProfileDays = 30

    // MARK: Collaborators

    private let client = LimitsClient()
    private let refresher = TokenRefresher()
    private let store = SampleStore()

    /// Deduplicated transcript events, replaced wholesale by each completed scan. Held on the
    /// main actor so aggregates can be recomputed for a new active-gap with no rescan.
    private var events: [UsageEvent] = []

    private var hasStarted = false
    private var pollTask: Task<Void, Never>?
    private var pollInFlight: Task<TimeInterval, Never>?
    private var scanTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var offlineSince: Date?
    private var lastScanAt: Date?
    /// Earliest the next request may be made while polls are failing. `lastUpdate` stops
    /// advancing during an outage, so the panel-open staleness gate alone would let every panel
    /// presentation fire another request and defeat both the backoff and an honoured
    /// `Retry-After`. Nil whenever the last poll did not fail.
    private var nextAttemptNotBefore: Date?
    /// Clean polls in a row at the current cadence, counting toward a cautious speed-up.
    private var cleanPolls = 0

    public init() {
        Prefs.registerDefaults()
    }

    // MARK: - Lifecycle

    /// Loads what is already on disk, starts the first poll, and kicks off the transcript scan.
    /// Idempotent, so it is safe to call from both app launch and a first panel presentation.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loadPersistedState(now: Date())
        startScan()
        pollTask = Task { [weak self] in await self?.runPollLoop(after: 0) }
    }

    /// Restarts the loop so a new cadence takes effect now instead of after the sleep already in
    /// flight — at the slow end of the range that would be a quarter of an hour of the setting
    /// appearing to do nothing.
    ///
    /// The first poll of the new loop is timed from the last reading, so changing the setting is
    /// not itself a reason to spend a request, and never lands inside a backoff or a `Retry-After`
    /// the app has already committed to. A poll still in flight is not cancelled: the restarted
    /// loop coalesces onto it the same way a panel-open refresh does.
    private func restartPollLoop() {
        pollTask?.cancel()
        let delay = delayBeforeNextPoll(now: Date())
        pollTask = Task { [weak self] in await self?.runPollLoop(after: delay) }
    }

    /// How long the restarted loop waits before its first request: enough to keep the new cadence
    /// relative to the last reading, and at least as long as any gate a failure has armed.
    private func delayBeforeNextPoll(now: Date) -> TimeInterval {
        var delay: TimeInterval = 0
        if let lastUpdate {
            delay = pollInterval - now.timeIntervalSince(lastUpdate)
        }
        if let nextAttemptNotBefore {
            delay = max(delay, nextAttemptNotBefore.timeIntervalSince(now))
        }
        return max(0, delay)
    }

    /// Refreshes only if the last successful poll has gone stale, which is the panel-open
    /// contract: opening the menu twice in five seconds must not fire two requests.
    public func refreshNow() async {
        await refresh(force: false)
    }

    /// `force` skips the staleness gate — for an explicit user-initiated refresh — and takes the
    /// transcript scan with it, since somebody who asked for fresh numbers means all of them and
    /// the panel's statistics come from the scan rather than the poll.
    ///
    /// It does not skip the deferral gate below, which is the difference between "the user is
    /// impatient" and "the app has already decided not to make this request". `canRefreshNow`
    /// reports that, so the button offering this can be disabled rather than silently doing
    /// nothing.
    public func refresh(force: Bool) async {
        guard hasStarted else {
            start()
            return
        }
        let now = Date()
        if !force {
            if let lastUpdate, now.timeIntervalSince(lastUpdate) < panelStaleInterval {
                return
            }
        }
        // A failing poll leaves `lastUpdate` frozen, so the staleness gate stops holding and every
        // panel open — or every press of the reload button — would issue a request the backoff, or
        // the server's own `Retry-After`, has explicitly deferred. A refused request is not free:
        // it widens the cadence for everything else.
        if let nextAttemptNotBefore, now < nextAttemptNotBefore { return }

        _ = await performPoll()
        if force { startScan() } else { maybeRescan(now: Date()) }
    }

    /// Whether an explicit refresh would actually do anything: nothing already in flight, and no
    /// deferral armed by a failed poll still standing.
    public var canRefreshNow: Bool {
        !isPolling && nextAttemptAt == nil
    }

    public func quit() {
        pollTask?.cancel()
        scanTask?.cancel()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Derived values

    /// The menu bar always shows the 5-hour window, never the most constrained one — a weekly
    /// figure that barely moves would make the icon useless as a live signal.
    public var fiveHourPercent: Double? { snapshot?.fiveHour?.utilization }
    public var fiveHourResetsAt: Date? { snapshot?.fiveHour?.resetsAt }
    public var fiveHourSeverity: Severity { snapshot?.severity(for: .fiveHour) ?? .normal }

    public var sevenDayPercent: Double? { snapshot?.sevenDay?.utilization }
    public var sevenDayResetsAt: Date? { snapshot?.sevenDay?.resetsAt }
    public var sevenDaySeverity: Severity { snapshot?.severity(for: .sevenDay) ?? .normal }

    /// Whether the menu bar ring should carry its cap dot.
    public var showsCapDot: Bool { fiveHourProjection?.willCapEarly ?? false }

    /// Today's bucket from the 30-day series, for the stats grid.
    public var today: DailyStat? { daily.last }

    /// The cadence the app is actually polling at, in seconds. Starts at whichever is slower of the
    /// user's setting and the interval last learned, widens on a 429, narrows after a sustained
    /// clean run down to the setting, and persists across launches so a limit learned today is not
    /// rediscovered tomorrow.
    public private(set) var pollInterval: TimeInterval = Prefs.effectivePollInterval()

    /// True once a 429 has pushed the cadence past the pace the user asked for, so the UI can say
    /// the refresh rate was reduced deliberately rather than looking broken.
    public var isThrottled: Bool {
        pollInterval > Prefs.Current.preferredPollInterval() + 0.5
    }

    public var isStale: Bool {
        guard let lastUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) >= panelStaleInterval
    }

    /// When the next request will actually be attempted, so an outage notice can say so instead
    /// of leaving the user to guess. `nil` once the gate has elapsed and a poll is imminent — the
    /// server's own `Retry-After` is deliberately not surfaced here, because this endpoint sends
    /// `Retry-After: 0` while rate-limiting and the real wait is our backoff.
    public var nextAttemptAt: Date? {
        guard let nextAttemptNotBefore, nextAttemptNotBefore > Date() else { return nil }
        return nextAttemptNotBefore
    }

    /// Wall-clock hours for a gap the user has not committed yet, so the settings slider can
    /// show the figure it is about to change without a full aggregate pass on every drag
    /// increment. Same in-memory events, no rescan.
    public func usageHoursPreview(gapMinutes: Int) -> UsageHours? {
        let settled = events.filter { $0.timestamp <= Date() }
        guard !settled.isEmpty else { return nil }
        return Aggregates.usageHours(from: settled, gap: TimeInterval(gapMinutes) * 60)
    }

    // MARK: - Aggregates

    /// Recomputed from the in-memory event array, never from disk: changing the active-gap
    /// slider is a pure function of events the app already holds, so it must not trigger a
    /// rescan of the whole corpus.
    public func recomputeAggregates() {
        let now = Date()
        let gap = Prefs.Current.activeGap()
        // `effortSplit`, `usageHours` and `cacheHitRatio` take no `now` and so count every event
        // handed to them, unlike the three above. A transcript written by a machine whose clock
        // runs fast would stretch wall clock and agent hours without bound, so the clamp the
        // others apply internally is applied here once, on behalf of all of them.
        let settled = events.filter { $0.timestamp <= now }
        sessions = Aggregates.sessions(from: settled, idleGap: gap, now: now)
        daily = Aggregates.daily(
            from: settled, days: Self.dailyHistoryDays, calendar: .current, now: now)
        models = Aggregates.modelSplit(from: settled, now: now)
        efforts = Aggregates.effortSplit(from: settled)
        usageHours = settled.isEmpty ? nil : Aggregates.usageHours(from: settled, gap: gap)
        cacheHitRatio = Aggregates.cacheHitRatio(from: settled)
        sidechainShare = Aggregates.sidechainShare(from: settled)
        hourProfile = Aggregates.hourProfile(
            events: settled, days: Self.hourProfileDays, now: now, calendar: .current)
        eventCount = settled.count
        recomputeCalibration(now: now)
    }

    /// The two figures that need both data sources at once — the poll series for what the
    /// limits did, the transcripts for what was spent while they did it.
    ///
    /// Recomputed from whichever of the two most recently changed, so a scan that lands between
    /// polls updates the exchange rate rather than waiting for the next reading.
    private func recomputeCalibration(now: Date) {
        let settled = events.filter { $0.timestamp <= now }
        fiveHourCalibration = ProjectionEngine.calibrate(
            kind: .fiveHour, samples: samples, events: settled, now: now)
        sevenDayCalibration = ProjectionEngine.calibrate(
            kind: .sevenDay, samples: samples, events: settled, now: now)
        cyclePace = sevenDayResetsAt.flatMap {
            Aggregates.cyclePace(events: settled, kind: .sevenDay, resetsAt: $0, now: now)
        }
    }

    private func recomputeProjections(now: Date) {
        guard let snapshot else {
            fiveHourProjection = nil
            sevenDayProjection = nil
            return
        }
        fiveHourProjection = ProjectionEngine.project(
            kind: .fiveHour, snapshot: snapshot, samples: samples, events: events, now: now)
        sevenDayProjection = ProjectionEngine.project(
            kind: .sevenDay, snapshot: snapshot, samples: samples, events: events, now: now)
        recomputeCalibration(now: now)
    }

    // MARK: - Persisted state

    private func loadPersistedState(now: Date) {
        try? store.load()
        _ = try? store.prune(olderThan: now.addingTimeInterval(-Self.sampleRetention))
        samples = store.samples

        // `health` stays `.live` until the first poll answers. The cached snapshot is a second
        // old on a normal relaunch, and flashing an offline banner for the few hundred
        // milliseconds before the first request lands would be a lie in the common case.
        if let cached = store.loadCachedSnapshot() {
            snapshot = cached
            lastUpdate = cached.fetchedAt
            recomputeProjections(now: now)
        }
    }

    /// Records one poll observation. `SampleStore.append` inserts into its own series only after
    /// the file write lands, so taking `store.samples` unconditionally would drop the point from
    /// the series the burn rate is fitted to whenever the write failed — and an unwritable
    /// support directory would then pin every 5-hour projection at `.paced` for the life of the
    /// process. Persistence is allowed to degrade; the fit is not. A later successful append
    /// hands authority back to the store, which costs the points written only in memory — one
    /// point of a 45-minute trailing fit, against a whole series otherwise.
    private func appendSample(_ sample: Sample) {
        do {
            try store.append(sample)
            samples = store.samples
        } catch {
            samples = Self.inserting(sample, into: samples)
        }
    }

    /// Ascending by `t`, matching `SampleStore`'s ordering so the two series stay interchangeable.
    private static func inserting(_ sample: Sample, into series: [Sample]) -> [Sample] {
        var result = series
        var index = result.count
        while index > 0, result[index - 1].t > sample.t { index -= 1 }
        result.insert(sample, at: index)
        return result
    }

    // MARK: - Polling

    /// `initialDelay` is for a loop restarted mid-flight; a loop started at launch polls at once.
    private func runPollLoop(after initialDelay: TimeInterval) async {
        if initialDelay > 0 {
            do { try await Task.sleep(for: .seconds(initialDelay)) } catch { return }
        }
        while !Task.isCancelled {
            let delay = await performPoll()
            maybeRescan(now: Date())
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return  // cancelled
            }
        }
    }

    /// Coalesces concurrent callers onto one request: the loop and a panel-open refresh can
    /// arrive together, and two simultaneous polls would append two samples one millisecond
    /// apart, which the burn-rate fit reads as an infinite slope.
    private func performPoll() async -> TimeInterval {
        if let pollInFlight { return await pollInFlight.value }
        let task = Task { [weak self] () -> TimeInterval in
            guard let self else { return AppModel.defaultPollInterval }
            return await self.pollOnce(now: Date())
        }
        pollInFlight = task
        isPolling = true
        let delay = await task.value
        pollInFlight = nil
        isPolling = false
        return delay
    }

    /// One read of the usage endpoint. Returns how long to wait before the next one.
    private func pollOnce(now: Date) async -> TimeInterval {
        // Re-read every poll rather than caching the token: Claude Code refreshes it on its own
        // schedule, and this app must pick that up without being relaunched.
        let stored: ClaudeCredentials
        do {
            stored = try Keychain.readCredentials()
        } catch KeychainError.notFound {
            return settle(.noCredentials)
        } catch {
            return fail(reason: message(for: error), now: now)
        }

        // Renew before the request rather than after a 401: the point is that a token close to
        // its deadline never gets used, so the app is not periodically down for the minutes
        // between expiry and whenever Claude Code next runs.
        let credentials: ClaudeCredentials
        switch await freshened(stored, now: now) {
        case .usable(let renewed):
            credentials = renewed
        case .signInRequired:
            return settle(.staleCredentials)
        case .unavailable(let reason):
            // The refresh failed for a reason that may not last — no network, a 500. If the
            // token still has life in it the request is worth making anyway; if it does not,
            // there is nothing to make it with, so back off and try the refresh again.
            guard !stored.isExpired(asOf: now) else { return fail(reason: reason, now: now) }
            credentials = stored
        }

        do {
            let fresh = try await client.fetch(accessToken: credentials.accessToken, now: now)
            apply(fresh, now: now)
            noteCleanPoll()
            return pollInterval
        } catch let error as LimitsClientError {
            switch error {
            case .unauthorized:
                // Re-read instead of trusting the copy from the top of this poll: the token may
                // have rotated mid-request.
                do {
                    let latest = try Keychain.readCredentials()
                    // A token the server rejects is spent whatever its stored deadline claims,
                    // so force a renewal rather than gating on `isExpired` — the deadline can
                    // be wrong, and the 401 is the authority on that.
                    if latest.accessToken != credentials.accessToken {
                        // Rotated mid-request, by Claude Code or by another instance of this
                        // app. The stored token is newer than the one that was refused, so
                        // spend the retry on it rather than a refresh.
                        return await retryAfterRenewal(with: latest, now: now)
                    }
                    switch await renew(latest, now: Date()) {
                    case .usable(let renewed):
                        return await retryAfterRenewal(with: renewed, now: now)
                    case .signInRequired:
                        return settle(.staleCredentials)
                    case .unavailable:
                        return fail(reason: error.description, now: now)
                    }
                } catch KeychainError.notFound {
                    // Signed out between the request and now — not an expired token, and the
                    // instruction the user needs is "sign in", not "renew".
                    return settle(.noCredentials)
                } catch {
                    // The item is there but will not answer. `DataHealth` has no case for that,
                    // and re-authenticating is the right instruction either way.
                    return settle(.staleCredentials)
                }

            case .rateLimited(let retryAfter):
                slowDown()
                let backoff = fail(reason: error.description, now: now)
                if let honoured = Self.honouredRetryAfter(retryAfter) {
                    // `fail` armed the gate with the backoff; a server-supplied delay outranks it.
                    nextAttemptNotBefore = now.addingTimeInterval(honoured)
                    return honoured
                }
                // No usable header — and this endpoint sends `Retry-After: 0` — so fall back to
                // the rate-limit floor rather than the generic ladder's first rung.
                let delay = max(backoff, pollInterval)
                nextAttemptNotBefore = now.addingTimeInterval(delay)
                return delay

            case .httpStatus, .transport, .decoding:
                return fail(reason: error.description, now: now)
            }
        } catch {
            return fail(reason: message(for: error), now: now)
        }
    }

    // MARK: - Token renewal

    /// What a renewal attempt left the app holding.
    private enum CredentialRenewal {
        /// Good for a request now — either freshly minted, or the stored pair when it had
        /// enough life left to leave alone.
        case usable(ClaudeCredentials)
        /// The refresh token is gone, expired, or refused. Only a new sign-in helps.
        case signInRequired
        /// The refresh could not be completed for a reason that may not last.
        case unavailable(String)
    }

    /// Renews only when the token is at or near its deadline; otherwise hands back what was
    /// stored. A refresh token is not free to spend — each one may be rotated away — so this
    /// is deliberately not "refresh every poll".
    private func freshened(
        _ credentials: ClaudeCredentials, now: Date
    ) async -> CredentialRenewal {
        guard credentials.expiresSoon(asOf: now, lead: Self.refreshLeadTime) else {
            return .usable(credentials)
        }
        return await renew(credentials, now: now)
    }

    /// Trades the refresh token for a new pair and writes it back to the shared Keychain item.
    ///
    /// The write is conditional on the stored refresh token still being the one spent here. If
    /// Claude Code refreshed first, its pair is the live one and this refresh is dropped — the
    /// last writer does not win, the first one does, which is what keeps two processes off each
    /// other's tokens.
    private func renew(_ credentials: ClaudeCredentials, now: Date) async -> CredentialRenewal {
        guard let spent = credentials.usableRefreshToken(asOf: now) else { return .signInRequired }

        let tokens: RefreshedTokens
        do {
            tokens = try await refresher.refresh(credentials, now: now)
        } catch let error as TokenRefreshError {
            return error.requiresSignIn ? .signInRequired : .unavailable(error.description)
        } catch {
            return .unavailable(message(for: error))
        }

        let renewed = credentials.applying(tokens)
        do {
            if try storeWithRetries(tokens, replacing: spent) {
                return .usable(renewed)
            }
            // Lost the race. Whatever is stored now was written by a process that refreshed
            // more recently, so it is the pair to use.
            return .usable(try Keychain.readCredentials())
        } catch KeychainError.notFound {
            return .signInRequired
        } catch {
            // Refreshed but could not persist. The new token still works for this app's own
            // requests, so it is used rather than thrown away — but Claude Code will not see
            // it, and if the server rotated the refresh token the CLI's stored copy is now
            // the stale one. Nothing here can undo that, which is why a refresh is only ever
            // spent close to expiry, when the CLI was about to make the same trade anyway.
            return .usable(renewed)
        }
    }

    /// The Keychain can refuse a write transiently — another process holding the item, a
    /// prompt being dismissed. Claude Code retries its own credential writes for the same
    /// reason; a lost write here means the CLI keeps a refresh token the server may have
    /// rotated away, so it is worth more than one attempt.
    private func storeWithRetries(
        _ tokens: RefreshedTokens, replacing spent: String
    ) throws -> Bool {
        var lastError: Error?
        for attempt in 0..<Self.credentialWriteAttempts {
            do {
                return try Keychain.storeRefreshedTokens(tokens, replacing: spent)
            } catch KeychainError.notFound {
                throw KeychainError.notFound
            } catch {
                lastError = error
                if attempt + 1 < Self.credentialWriteAttempts {
                    // Short and blocking on purpose: this runs between a successful refresh
                    // and the poll that uses it, and the whole point is to land the write.
                    Thread.sleep(forTimeInterval: Self.credentialWriteRetryDelay)
                }
            }
        }
        throw lastError ?? KeychainError.unhandled(errSecIO)
    }

    /// One more read of the usage endpoint after a renewal, so a poll that started on a token
    /// the server had already retired still returns fresh numbers instead of an outage.
    private func retryAfterRenewal(
        with credentials: ClaudeCredentials, now: Date
    ) async -> TimeInterval {
        do {
            let fresh = try await client.fetch(accessToken: credentials.accessToken, now: now)
            apply(fresh, now: now)
            noteCleanPoll()
            return pollInterval
        } catch let error as LimitsClientError {
            switch error {
            case .unauthorized:
                // A token minted seconds ago and refused anyway. Another renewal would be
                // refused too, so stop and ask for a sign-in rather than loop.
                return settle(.staleCredentials)
            case .rateLimited:
                slowDown()
                let backoff = fail(reason: error.description, now: now)
                let delay = max(backoff, pollInterval)
                nextAttemptNotBefore = now.addingTimeInterval(delay)
                return delay
            case .httpStatus, .transport, .decoding:
                return fail(reason: error.description, now: now)
            }
        } catch {
            return fail(reason: message(for: error), now: now)
        }
    }

    private func apply(_ fresh: UsageSnapshot, now: Date) {
        snapshot = fresh
        lastUpdate = fresh.fetchedAt
        consecutiveFailures = 0
        offlineSince = nil
        nextAttemptNotBefore = nil
        setHealth(.live)

        try? store.cacheSnapshot(fresh)
        appendSample(Sample(snapshot: fresh))
        recomputeProjections(now: now)

        // Alerts are evaluated only here, not after a scan: a transcript pass changes the token
        // aggregates but never the utilization an alert is about. `Notifier` no-ops unless the
        // user turned notifications on, and it keys fired alerts by `resetsAt`, so re-evaluating
        // every poll cannot re-notify for the same window.
        Notifier.shared.evaluate(fiveHour: fiveHourProjection, sevenDay: sevenDayProjection, now: now)
    }

    /// A credential state, rather than a transport failure: no request was made, so there is
    /// nothing to back off from and the cached snapshot stays on screen. The Keychain is also
    /// the cheap half of a poll, so these states keep the normal cadence and stay open to a
    /// panel-open refresh — that is how a token Claude Code just rotated is picked up at once.
    private func settle(_ state: DataHealth) -> TimeInterval {
        consecutiveFailures = 0
        offlineSince = nil
        nextAttemptNotBefore = nil
        setHealth(state)
        return pollInterval
    }

    private func fail(reason: String, now: Date) -> TimeInterval {
        consecutiveFailures += 1
        // `since` is when the numbers on screen were last true, so the panel can say how old
        // the cached snapshot is. It falls back to the first failure when nothing has ever
        // succeeded, which is the cold-start-with-no-network case.
        let since = offlineSince ?? lastUpdate ?? now
        offlineSince = since
        setHealth(.offline(since: since, reason: reason))
        let delay = backoffDelay()
        nextAttemptNotBefore = now.addingTimeInterval(delay)
        return delay
    }

    // MARK: - Adaptive cadence

    /// A panel opened within this long of the last successful poll shows what it already has,
    /// rather than spending a request. Tracks the live cadence: at a fixed 20s it fired on nearly
    /// every open, roughly doubling traffic to re-fetch what the loop had just refreshed.
    private var panelStaleInterval: TimeInterval { pollInterval * 0.9 }

    /// Widen the interval and remember it. Called on a 429 — the one unambiguous signal that the
    /// current pace is too fast. Multiplicative so a persistent limit is escaped in a few steps
    /// rather than crawled away from. Outranks the user's setting, which is why that setting is a
    /// target and not a guarantee: the account's budget is not ours alone to spend.
    private func slowDown() {
        cleanPolls = 0
        let widened = min(pollInterval * Self.slowdownFactor, Self.maximumPollInterval)
        guard widened > pollInterval else { return }
        pollInterval = widened
        Prefs.setLearnedPollInterval(widened)
    }

    /// Give a little of the interval back after a sustained clean run, so a cadence widened during
    /// a busy hour does not stay slow forever. Stops at the pace the user asked for rather than at
    /// the app's own floor — a cadence nobody asked to be fast has no reason to keep accelerating.
    private func noteCleanPoll() {
        let target = Prefs.Current.preferredPollInterval()
        guard pollInterval > target else { return }
        cleanPolls += 1
        guard cleanPolls >= Self.successesBeforeSpeedup else { return }
        cleanPolls = 0
        pollInterval = max(pollInterval * Self.speedupFactor, target)
        Prefs.setLearnedPollInterval(pollInterval)
    }

    /// Adopts the cadence the user has just chosen in settings.
    ///
    /// The choice supersedes what the app had learned, in both directions. Downwards that is
    /// obvious. Upwards it means dropping a backoff a 429 taught the app, which is deliberate: the
    /// learned value is a guess about a shared budget that may be hours stale, and a setting that
    /// visibly does nothing is worse than one refused request. If the endpoint still objects, the
    /// next 429 widens it again from here — and `isThrottled` says so in the place the setting was
    /// changed.
    public func applyPreferredPollInterval() {
        let chosen = Prefs.Current.preferredPollInterval()
        // Returning early is safe even though the target itself moved: the loop is already sleeping
        // for the interval being asked for, and `noteCleanPoll` reads the target live rather than
        // from anything cached here.
        guard chosen != pollInterval else { return }
        cleanPolls = 0
        pollInterval = chosen
        Prefs.setLearnedPollInterval(chosen)
        guard hasStarted else { return }
        restartPollLoop()
    }

    /// First rung is the current cadence, so a transport blip never retries faster than the pace
    /// the app has settled on.
    private func backoffDelay() -> TimeInterval {
        let step = Double(max(1, consecutiveFailures) - 1)
        return min(pollInterval * pow(2, step), Self.maximumBackoff)
    }

    /// `Retry-After` as sent, floored at a second and bounded. `LimitsClient` only guarantees
    /// the value is finite and non-negative, so a header asking for a day would otherwise park
    /// the app until it is relaunched. `nil` means there was nothing usable and the backoff
    /// stands. Deliberately not clamped to `maximumBackoff` — a server telling us to wait
    /// longer than our own schedule is information, not noise.
    private static func honouredRetryAfter(_ retryAfter: TimeInterval?) -> TimeInterval? {
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return nil }
        return min(max(retryAfter, 1), maximumHonouredRetryAfter)
    }

    /// `@Observable` notifies on every write, equal or not, so an unchanged health assignment
    /// each minute would re-render the whole panel for nothing.
    private func setHealth(_ new: DataHealth) {
        guard health != new else { return }
        health = new
    }

    /// Human-readable `reason` for `DataHealth.offline`. `LimitsClientError` carries its own
    /// short form; `KeychainError` is a `LocalizedError`; anything else falls back.
    private func message(for error: Error) -> String {
        if let limits = error as? LimitsClientError { return limits.description }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Transcript scanning

    private func startScan() {
        guard scanTask == nil else { return }
        isScanning = true
        lastScanAt = Date()
        // Detached, and with its own scanner instance: the first pass reads the entire corpus,
        // which must never block panel presentation, and `TranscriptScanner` is not `Sendable`, so
        // nothing but the resulting value types may cross back.
        let work = Task.detached(priority: .utility) { ScanWorker.run() }
        scanTask = Task { [weak self] in
            let outcome = await work.value
            guard let self else { return }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: ScanOutcome) {
        scanTask = nil
        isScanning = false
        lastScanAt = Date()
        events = outcome.events
        if let factor = outcome.inflationFactor { inflationFactor = factor }
        recomputeAggregates()
        recomputeProjections(now: Date())
    }

    private func maybeRescan(now: Date) {
        guard scanTask == nil else { return }
        guard let lastScanAt else {
            startScan()
            return
        }
        guard now.timeIntervalSince(lastScanAt) >= Self.rescanInterval else { return }
        startScan()
    }
}

// MARK: - Detached scan

/// One incremental transcript pass, off the main actor.
///
/// Deliberately outside `AppModel`: the scanner it creates must not be reachable from the main
/// actor, and only `ScanOutcome` — all value types — travels back.
private enum ScanWorker {
    static func run() -> ScanOutcome {
        let scanner = TranscriptScanner()
        try? scanner.loadPersistedState()
        let result = try? scanner.scan()
        // Persisted even when the pass threw partway: the event cache is written before the
        // offsets, so the worst a partial write costs is bytes re-read next time.
        try? scanner.persistState()
        return ScanOutcome(events: scanner.events, inflationFactor: result?.inflationFactor)
    }
}

private struct ScanOutcome: Sendable {
    let events: [UsageEvent]
    let inflationFactor: Double?
}
