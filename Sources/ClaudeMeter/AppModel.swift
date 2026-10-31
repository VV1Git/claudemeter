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
    /// True when the shared Keychain item's partition list no longer admits `apple-tool:`, so
    /// every `claude` command is about to start raising a password dialog.
    ///
    /// This app cannot cause that any more — it never writes the item — so what this reports is
    /// damage left by a version that did, and it should clear for good once repaired.
    ///
    /// Deliberately not a `DataHealth` case. `DataHealth` says whether the numbers on screen are
    /// live, and during a lockout they generally are: it is the CLI that has lost access, not this
    /// app. The two states are independent and the panel shows them as two rows.
    public private(set) var cliLockedOut = false
    /// The `security` line that puts the evicted identity back, or nil when one cannot be built
    /// honestly. Held here rather than read from the view, because building it queries the
    /// Keychain and a SwiftUI body runs on every layout pass.
    public private(set) var partitionRepairCommand: String?
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

    // MARK: Collaborators

    private let client = LimitsClient()
    /// Every Keychain call in the app goes through here, and it is an actor off the main thread.
    /// That is the whole fix for the panel freezing: securityd round trips — and, when this app
    /// has been evicted from the item's partition list, a modal authorization dialog — no longer
    /// happen anywhere the UI can be waiting on them.
    private let credentials = CredentialStore()
    private let store = SampleStore()

    /// Deduplicated transcript events, replaced wholesale by each completed scan. Held on the
    /// main actor so aggregates can be recomputed for a new active-gap with no rescan.
    private var events: [UsageEvent] = []

    private var hasStarted = false
    private var pollTask: Task<Void, Never>?
    private var pollInFlight: Task<TimeInterval, Never>?
    private var scanTask: Task<Void, Never>?
    /// The rollup pass, held so a newer request can cancel an older one. Dragging the idle-gap
    /// slider asks for one per minute crossed and only the last answer is wanted.
    private var aggregateTask: Task<Void, Never>?
    /// The same, for the cheaper calibration-only pass a poll triggers.
    private var calibrationTask: Task<Void, Never>?
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
        // Off the main actor and not awaited here, so a slow securityd cannot delay the first
        // panel. The first poll answers the same question a moment later anyway.
        Task { [weak self] in
            guard let self else { return }
            self.hasDedicatedToken = await self.credentials.hasDedicatedToken()
        }
        pollTask = Task { [weak self] in await self?.runPollLoop(after: 0) }
    }

    /// Reads the credential with the system's authorization dialog permitted.
    ///
    /// The one entry point in the app that may raise that dialog, and it exists so the dialog is
    /// something the user asked for a moment ago rather than something that appeared over their
    /// work. Everything else takes a refusal for an answer. Runs on the actor, so even the modal
    /// wait costs the UI nothing.
    public func authorizeKeychain() async {
        do {
            _ = try await credentials.authorize()
        } catch let error as KeychainError where error.isAuthorizationProblem {
            // Dismissed, or denied. Either way it is an answer, and the app does not ask again on
            // its own initiative — but the state must stay `.needsAuthorization` so the button is
            // still on screen for a user who dismissed the dialog by accident. Reporting these as
            // an outage would swap the notice for one carrying no way back, and leave them
            // waiting out a poll interval to get the button again.
            setHealth(.needsAuthorization)
            return
        } catch {
            setHealth(.offline(since: lastUpdate ?? Date(), reason: message(for: error)))
            return
        }
        await refreshPartitionState(now: Date(), force: true)
        await refresh(force: true)
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
    public var showsCapDot: Bool { sevenDayProjection?.willCapEarly ?? false }

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

    // MARK: - Aggregates

    /// Recomputes every rollup the panel shows, off the main actor.
    ///
    /// Eight passes over the whole corpus, several of which sort it and one of which prices every
    /// event four times — around four milliseconds at thirty thousand events, and linear in a
    /// corpus that only grows. It used to run on the main actor on every poll, every scan and
    /// every increment of the idle-gap slider; now it runs on a background task and the results,
    /// all value types, are assigned in one hop back. See `Aggregation` for why this is a bound
    /// rather than a speed-up.
    ///
    /// Coalescing rather than queueing: a drag across the slider fires this many times, and only
    /// the last answer is wanted. An in-flight pass is cancelled, and its result discarded.
    public func recomputeAggregates() {
        aggregateTask?.cancel()
        let events = self.events
        let gap = Prefs.Current.activeGap()
        // The stored handle *is* the detached task, so cancelling it actually marks it cancelled.
        // Wrapping a detached task inside another and cancelling the wrapper does not: detached
        // work does not inherit cancellation, and awaiting a non-throwing task does not resume
        // early — the pass would run to completion regardless and only its result be discarded.
        aggregateTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounced, because the corpus walk is synchronous and so cannot be interrupted
            // partway: once it starts, cancelling costs a whole pass. Sleeping first means a
            // superseding call cancels this one while it is still cheap to cancel, which is what
            // turns a drag across the idle-gap slider into one computation instead of one per
            // minute crossed.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            let computed = Aggregation.compute(events: events, gap: gap, now: Date())
            guard !Task.isCancelled else { return }
            await self?.apply(computed)
        }
        // The calibration figures move with the events too, but they have their own single
        // producer — see `recomputeCalibration` — so they are asked for rather than computed here.
        recomputeCalibration()
    }

    private func applyCalibration(_ computed: CalibrationOutcome) {
        fiveHourCalibration = computed.fiveHour
        sevenDayCalibration = computed.sevenDay
        cyclePace = computed.cyclePace
    }

    private func apply(_ computed: Aggregation) {
        sessions = computed.sessions
        daily = computed.daily
        models = computed.models
        efforts = computed.efforts
        usageHours = computed.usageHours
        cacheHitRatio = computed.cacheHitRatio
        sidechainShare = computed.sidechainShare
        hourProfile = computed.hourProfile
        eventCount = computed.eventCount
    }

    /// Just the exchange rates and cycle pace, which is all a new poll sample can have changed.
    ///
    /// Off the main actor for the same reason as the full pass — it still walks the corpus twice
    /// — but kept separate from it so a poll every three minutes does not pay for nine passes to
    /// refresh three numbers.
    private func recomputeCalibration() {
        calibrationTask?.cancel()
        let events = self.events
        let samples = self.samples
        let resetsAt = sevenDayResetsAt
        // Detached and stored directly, for the reason given in `recomputeAggregates`.
        calibrationTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            let computed = CalibrationOutcome.compute(
                events: events, samples: samples, sevenDayResetsAt: resetsAt, now: Date())
            guard !Task.isCancelled else { return }
            await self?.applyCalibration(computed)
        }
    }

    /// The projections alone, which are cheap enough to keep synchronous.
    ///
    /// `ProjectionEngine.project` fits a burn rate over the trailing sample series and reads the
    /// events for a variation estimate, an activity profile and a live-burst signal, so it is a
    /// different order of work from the rollups above and a poll can afford it inline. The
    /// calibration it used to drag along with it — two full passes over the corpus — has moved to
    /// `recomputeAggregates`, which is why a poll now schedules that rather than doing the work
    /// itself.
    ///
    /// The idle gap comes from the same preference the sessions list is clustered with. It is the
    /// user's own answer to "how long a pause means I have stopped working", and the projection
    /// asks exactly that question of the last few minutes.
    private func recomputeProjections(now: Date) {
        guard let snapshot else {
            fiveHourProjection = nil
            sevenDayProjection = nil
            return
        }
        let idleGap = Prefs.Current.activeGap()
        fiveHourProjection = ProjectionEngine.project(
            kind: .fiveHour, snapshot: snapshot, samples: samples, events: events, now: now,
            idleGap: idleGap)
        sevenDayProjection = ProjectionEngine.project(
            kind: .sevenDay, snapshot: snapshot, samples: samples, events: events, now: now,
            idleGap: idleGap)
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
        // Throttled inside the store, because the list only changes when somebody writes the
        // item. This app no longer does, so what is being watched for here is damage an earlier
        // build left behind, and the moment the user's repair clears it.
        await refreshPartitionState(now: now)

        let resolved: ResolvedCredential
        do {
            resolved = try await credentials.current(now: now)
        } catch KeychainError.notFound {
            return settle(.noCredentials)
        } catch let error as KeychainError where error.isAuthorizationProblem {
            // Evicted from the item's partition list, with nothing cached that is still good.
            // Not a failure to back off from — no request was made, and no amount of waiting
            // fixes it. The panel offers the user the one gesture that does.
            return settle(.needsAuthorization)
        } catch {
            return fail(reason: message(for: error), now: now)
        }

        let usable: ResolvedCredential
        switch CredentialPolicy.decide(
            resolved, now: now, lead: CredentialStore.refreshLeadTime)
        {
        case .useStored:
            usable = resolved
        case .renew:
            switch await renewedDedicated(now: now) {
            case .renewed(let credential):
                usable = credential
            case .signInRequired:
                return settle(.staleCredentials)
            case .unavailable(let reason):
                // The renewal failed for a reason that may not last — no network, a 500. If the
                // token still has life in it the request is worth making anyway.
                guard !resolved.credentials.isExpired(asOf: now) else {
                    return fail(reason: reason, now: now)
                }
                usable = resolved
            }
        case .waitForClaudeCode:
            // Not a failure, so it does not walk the backoff ladder: the token is simply old and
            // the process that owns it has not renewed it yet. Keeping the normal cadence is what
            // picks the new token up within one poll of `claude` running.
            return settle(.waitingForClaudeCode)
        case .signInRequired:
            return settle(.staleCredentials)
        }

        do {
            let fresh = try await client.fetch(
                accessToken: usable.credentials.accessToken, now: now)
            apply(fresh, now: now)
            noteCleanPoll()
            return pollInterval
        } catch let error as LimitsClientError {
            switch error {
            case .unauthorized:
                // A token the server rejects is spent whatever its stored deadline claims, so
                // drop the cached copy and re-read: the deadline can be wrong, and the 401 is
                // the authority on that.
                await credentials.invalidate()
                do {
                    let latest = try await credentials.current(now: Date())
                    if latest.credentials.accessToken != usable.credentials.accessToken {
                        // Rotated mid-request, by Claude Code or by another instance of this
                        // app. The stored token is newer than the one that was refused, so
                        // spend the retry on it rather than a renewal.
                        return await retryAfterRenewal(with: latest.credentials, now: now)
                    }
                    switch CredentialPolicy.decideAfterRejection(latest, now: Date()) {
                    case .renew:
                        switch await renewedDedicated(now: Date()) {
                        case .renewed(let credential):
                            return await retryAfterRenewal(with: credential.credentials, now: now)
                        case .signInRequired:
                            return settleAfterRefusal(.staleCredentials, now: now)
                        case .unavailable:
                            return fail(reason: error.description, now: now)
                        }
                    case .waitForClaudeCode, .useStored:
                        // The server refused a token whose stored deadline may still be in the
                        // future — revoked, or signed out on another machine. Nothing this app
                        // does fixes it, so the ladder runs: without it the same rejected request
                        // would go out every cadence, and again on every panel open.
                        return settleAfterRefusal(.waitingForClaudeCode, now: now)
                    case .signInRequired:
                        return settleAfterRefusal(.staleCredentials, now: now)
                    }
                } catch KeychainError.notFound {
                    // Signed out between the request and now — not an expired token, and the
                    // instruction the user needs is "sign in", not "renew". No further request is
                    // going to be made against a credential that is gone, so this one settles.
                    return settle(.noCredentials)
                } catch let error as KeychainError where error.isAuthorizationProblem {
                    return settle(.needsAuthorization)
                } catch {
                    // The item is there but will not answer. `DataHealth` has no case for that,
                    // and re-authenticating is the right instruction either way.
                    return settleAfterRefusal(.staleCredentials, now: now)
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
        /// Good for a request now.
        case renewed(ResolvedCredential)
        /// The refresh token is gone, expired, or refused. Only a new credential helps.
        case signInRequired
        /// The refresh could not be completed for a reason that may not last.
        case unavailable(String)
    }

    /// Renews the credential the user dedicated to this app.
    ///
    /// Only ever reached for a `.dedicated` credential — `CredentialPolicy` returns `.renew` for
    /// nothing else — and that restriction is the point. Renewing here spends this app's own
    /// refresh token and writes this app's own Keychain item, so no other process loses a token
    /// and no other identity is evicted from a partition list. The same operation on Claude
    /// Code's credential would do both, which is why it is not available at all.
    private func renewedDedicated(now: Date) async -> CredentialRenewal {
        do {
            guard let renewed = try await credentials.renewDedicated(now: now) else {
                // Nothing to renew with. The caller decides whether what it holds still serves.
                return .signInRequired
            }
            return .renewed(renewed)
        } catch let error as TokenRefreshError {
            return error.requiresSignIn ? .signInRequired : .unavailable(error.description)
        } catch {
            return .unavailable(message(for: error))
        }
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
                // refused too, so stop and ask for a sign-in rather than loop — and hold the
                // gate, because this poll has now spent two refused requests.
                return settleAfterRefusal(.staleCredentials, now: now)
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
        recomputeCalibration()

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

    /// A credential state arrived at *after* a request was made and refused.
    ///
    /// `settle` is wrong for these, and the difference is not cosmetic. It clears
    /// `nextAttemptNotBefore` on the grounds that no request was made and there is nothing to back
    /// off from — true when a stale deadline is spotted before asking, false here. A token the
    /// server rejects while its stored deadline is still in the future (revoked, or signed out on
    /// another machine) would otherwise be re-sent every cadence for ever, and, because the panel
    /// gate reads the same cleared field, on every panel open as well.
    ///
    /// So the health is the one the user needs and the backoff ladder still runs. `offlineSince`
    /// is deliberately left alone: these are not outages, and the panel must not start reporting
    /// how long the numbers have been stale for a credential problem.
    private func settleAfterRefusal(_ state: DataHealth, now: Date) -> TimeInterval {
        consecutiveFailures += 1
        setHealth(state)
        let delay = backoffDelay()
        nextAttemptNotBefore = now.addingTimeInterval(delay)
        return delay
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

    /// Records whether Claude Code can still reach its own credential item.
    ///
    /// This app cannot cause a lockout any more — it never writes that item — so what this
    /// watches for is damage an earlier build left behind, and the moment the user's repair
    /// clears it. Reading an ACL needs no authorization and decrypts nothing, and the store
    /// throttles it besides, so a poll pays almost nothing for the check.
    ///
    /// Both fields are compared before assigning: `@Observable` notifies on every write, and an
    /// unchanged answer every few minutes would re-render the panel for nothing.
    private func refreshPartitionState(now: Date, force: Bool = false) async {
        let state = await credentials.partitionState(now: now, force: force)
        if cliLockedOut != state.cliLockedOut { cliLockedOut = state.cliLockedOut }
        if partitionRepairCommand != state.repairCommand {
            partitionRepairCommand = state.repairCommand
        }
    }

    // MARK: - Signing in

    /// How far along a browser sign-in is, so Settings can show the right control.
    public enum SignInStage: Equatable, Sendable {
        case idle
        /// The browser is open and the loopback port is waiting for it to come back.
        case waitingForBrowser
        /// No loopback port could be had, so the browser was sent to the page that displays the
        /// code, and the user has to bring it back by hand.
        case awaitingPastedCode
    }

    public private(set) var signInStage: SignInStage = .idle

    /// The PKCE secret and state for the sign-in in flight. Held only for as long as the flow
    /// runs: the verifier is what proves this process started the request, so it is discarded
    /// the moment the code has been spent or the attempt abandoned.
    private var pendingSignIn: (pkce: PKCEPair, state: String, redirectURI: String)?

    /// Starts a browser sign-in and adopts what comes back as ClaudeMeter's own credential.
    ///
    /// This is the path that ends the Keychain prompts without sending the user to a terminal.
    /// It is the same OAuth exchange `claude setup-token` performs, so what it produces is a
    /// credential of exactly the shape `CredentialStore` already renews — and better than a
    /// pasted one, which carries no refresh token and therefore has to be redone when it
    /// expires.
    ///
    /// Returns the error to show, or nil on success. On success the credential lands in this
    /// app's own Keychain item; Claude Code's is neither read nor written.
    public func signIn() async -> String? {
        cancelSignIn()

        let pkce = PKCEPair()
        let state = OAuthSignIn.makeState()

        // Loopback first, because it is the whole difference between one click and a copy-paste.
        // A port that cannot be opened is not a failure worth reporting — it is the cue to take
        // the manual route, which always works.
        guard let receiver = try? LoopbackCodeReceiver() else {
            return beginManualSignIn(pkce: pkce, state: state)
        }

        let redirectURI = OAuthSignIn.loopbackRedirectURI(port: receiver.port)
        // Deliberately not recorded in `pendingSignIn`: on this route the code comes back to
        // this process, so there is no second step to hold a verifier for, and state that only
        // one of two paths reads is state the other path can get wrong.
        signInStage = .waitingForBrowser
        NSWorkspace.shared.open(
            OAuthSignIn.authorizationURL(
                challenge: pkce.challenge, state: state, redirectURI: redirectURI))

        do {
            let code = try await receiver.code()
            try OAuthSignIn.validate(code, expecting: state)
            return await adopt(code, verifier: pkce.verifier, redirectURI: redirectURI)
        } catch OAuthSignInError.cancelled {
            // The user's own doing, so there is nothing to tell them they do not already know.
            signInStage = .idle
            pendingSignIn = nil
            return nil
        } catch OAuthSignInError.timedOut {
            // Either the user walked away, or this port was refused as a redirect — which no
            // amount of waiting fixes. The second is the one worth naming, because the route
            // that does not need a port is right there and the user would not otherwise think
            // to try it.
            signInStage = .idle
            pendingSignIn = nil
            return "The browser did not come back. Try again \u{2014} or, if it keeps happening, use "
                + "a token from `claude setup-token` below, which needs no local port."
        } catch {
            signInStage = .idle
            pendingSignIn = nil
            return message(for: error)
        }
    }

    /// Sends the browser to the page that displays the code, for the user to bring back.
    ///
    /// Always returns nil: reaching this point is not an error the user needs to hear about,
    /// only a different set of instructions, which `signInStage` is what conveys.
    private func beginManualSignIn(pkce: PKCEPair, state: String) -> String? {
        pendingSignIn = (pkce, state, OAuthSignIn.manualRedirectURI)
        signInStage = .awaitingPastedCode
        NSWorkspace.shared.open(
            OAuthSignIn.authorizationURL(
                challenge: pkce.challenge,
                state: state,
                redirectURI: OAuthSignIn.manualRedirectURI))
        return nil
    }

    /// Finishes a sign-in with the `code#state` string the callback page displayed.
    public func completeSignIn(withPastedCode pasted: String) async -> String? {
        guard let pending = pendingSignIn else {
            return "That sign-in is no longer in progress. Start a new one."
        }
        do {
            let code = try OAuthSignIn.parsePastedCode(pasted)
            try OAuthSignIn.validate(code, expecting: pending.state)
            return await adopt(
                code, verifier: pending.pkce.verifier, redirectURI: pending.redirectURI)
        } catch {
            return message(for: error)
        }
    }

    /// Spends the code, stores what comes back, and proves it works before calling it a success.
    ///
    /// The validating poll is the same belt-and-braces `adoptDedicatedToken` applies, and for the
    /// same reason: a credential that the usage endpoint will not accept should be reported while
    /// the user is still in Settings, not silently at the next poll. A scope set that turns out
    /// too narrow would surface exactly here.
    private func adopt(
        _ code: AuthorizationCode, verifier: String, redirectURI: String
    ) async -> String? {
        let stored: ResolvedCredential
        do {
            stored = try await credentials.adoptAuthorizationCode(
                code, verifier: verifier, redirectURI: redirectURI)
        } catch {
            signInStage = .idle
            pendingSignIn = nil
            return message(for: error)
        }

        signInStage = .idle
        pendingSignIn = nil
        hasDedicatedToken = await credentials.hasDedicatedToken()

        do {
            let fresh = try await client.fetch(
                accessToken: stored.credentials.accessToken, now: Date())
            apply(fresh, now: Date())
            noteCleanPoll()
            return nil
        } catch let error as LimitsClientError {
            // Only an outright refusal is worth undoing. A transport failure says nothing about
            // the credential, and discarding a good one because the network blinked would send
            // the user back through the browser for no reason.
            if case .unauthorized = error {
                await credentials.forgetDedicatedToken()
                hasDedicatedToken = await credentials.hasDedicatedToken()
                return "The endpoint refused the credential that sign-in produced \u{2014} usually "
                    + "the scopes it was granted. Nothing is lost: ClaudeMeter has gone back to "
                    + "reading Claude Code\u{2019}s credential."
            }
            return error.description
        } catch {
            return message(for: error)
        }
    }

    /// Abandons a sign-in, discarding the verifier with it.
    ///
    /// Only clears this model's state. A loopback wait is unblocked by cancelling the task that
    /// is awaiting `signIn()`, which is the caller's to hold — an `AppModel` that owned the task
    /// as well would have two owners for one cancellation and no way to order them.
    public func cancelSignIn() {
        pendingSignIn = nil
        signInStage = .idle
    }

    // MARK: - The dedicated token

    /// True when the user has given ClaudeMeter a token of its own, so the panel can say which
    /// credential the numbers came from.
    public private(set) var hasDedicatedToken = false

    /// Adopts a token from `claude setup-token` and immediately spends it on a real request, so
    /// a token that does not work for this endpoint is reported now rather than at the next poll.
    ///
    /// Returns the error to show, or nil on success. Nothing here reads or writes Claude Code's
    /// credential item.
    public func adoptDedicatedToken(_ token: String) async -> String? {
        // The stored credential, not the argument: the store trims what it saves, and validating
        // the untrimmed string would spend a different token from the one on disk — which a
        // terminal copy, newline and all, makes the common case rather than the odd one. The
        // request would 401 and the branch below would then delete a token that was fine.
        let stored: ResolvedCredential
        do {
            stored = try await credentials.adoptDedicatedToken(token)
        } catch {
            return message(for: error)
        }
        hasDedicatedToken = await credentials.hasDedicatedToken()
        do {
            let fresh = try await client.fetch(
                accessToken: stored.credentials.accessToken, now: Date())
            apply(fresh, now: Date())
            noteCleanPoll()
            return nil
        } catch let error as LimitsClientError {
            // Kept rather than discarded on a refusal: the token may be fine and the network may
            // not be. Only an outright rejection is worth undoing, since that one is about the
            // token itself and leaving it in place would break every later poll.
            if case .unauthorized = error {
                await credentials.forgetDedicatedToken()
                hasDedicatedToken = await credentials.hasDedicatedToken()
                return "The endpoint refused that token. Check you pasted all of it, and that it "
                    + "came from `claude setup-token`."
            }
            return error.description
        } catch {
            return message(for: error)
        }
    }

    /// Forgets the dedicated token and goes back to reading Claude Code's credential.
    public func forgetDedicatedToken() async {
        await credentials.forgetDedicatedToken()
        hasDedicatedToken = await credentials.hasDedicatedToken()
        await refresh(force: true)
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
