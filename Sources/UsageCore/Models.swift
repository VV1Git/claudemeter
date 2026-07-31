import Foundation

// MARK: - Severity

/// How close a limit is to exhaustion. Mirrors the `severity` string the usage
/// API returns, with a numeric fallback for payloads that omit it.
public enum Severity: String, Codable, Sendable, CaseIterable {
    case normal
    case warning
    case critical

    /// Fallback classification when the API doesn't supply a severity.
    public static func fromPercent(_ percent: Double) -> Severity {
        switch percent {
        case ..<70: .normal
        case ..<90: .warning
        default: .critical
        }
    }
}

// MARK: - Usage snapshot (from GET /api/oauth/usage)

/// One of the named rate-limit windows (`five_hour`, `seven_day`, ...).
public struct LimitWindow: Codable, Sendable, Equatable {
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// An entry from the API's generic `limits[]` array. Decoded generically rather
/// than mapped onto known window names, since which windows are populated varies
/// by plan and new `kind`s appear over time.
public struct RateLimit: Codable, Sendable, Equatable {
    public let kind: String       // "session", "weekly_all", "weekly_scoped", ...
    public let group: String      // "session", "weekly"
    public let percent: Double
    public let severity: Severity
    public let resetsAt: Date?
    public let scopeLabel: String?  // e.g. the model display name for weekly_scoped
    public let isActive: Bool

    public init(
        kind: String, group: String, percent: Double, severity: Severity,
        resetsAt: Date?, scopeLabel: String?, isActive: Bool
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scopeLabel = scopeLabel
        self.isActive = isActive
    }
}

/// Extra-usage (credit) state. Purely informational in the UI.
public struct ExtraUsage: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let utilization: Double?
    public let spendLimitReached: Bool

    public init(isEnabled: Bool, utilization: Double?, spendLimitReached: Bool) {
        self.isEnabled = isEnabled
        self.utilization = utilization
        self.spendLimitReached = spendLimitReached
    }
}

/// A single successful read of the usage endpoint.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let limits: [RateLimit]
    public let extraUsage: ExtraUsage?
    public let fetchedAt: Date

    public init(
        fiveHour: LimitWindow?, sevenDay: LimitWindow?, limits: [RateLimit],
        extraUsage: ExtraUsage?, fetchedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.extraUsage = extraUsage
        self.fetchedAt = fetchedAt
    }

    /// Which window to surface in the menu bar: whichever is further along.
    /// Falls back to the other window if only one is present.
    public var mostConstrained: (kind: WindowKind, window: LimitWindow)? {
        switch (fiveHour, sevenDay) {
        case let (.some(f), .some(s)):
            return s.utilization > f.utilization ? (.sevenDay, s) : (.fiveHour, f)
        case let (.some(f), .none):
            return (.fiveHour, f)
        case let (.none, .some(s)):
            return (.sevenDay, s)
        case (.none, .none):
            return nil
        }
    }

    /// Severity for a window, preferring the API's own classification when the
    /// matching `limits[]` entry carries one.
    public func severity(for kind: WindowKind) -> Severity {
        let group = kind == .fiveHour ? "session" : "weekly"
        if let match = limits.first(where: { $0.group == group && $0.kind != "weekly_scoped" }) {
            return match.severity
        }
        let percent = (kind == .fiveHour ? fiveHour : sevenDay)?.utilization ?? 0
        return .fromPercent(percent)
    }
}

public enum WindowKind: String, Codable, Sendable {
    case fiveHour
    case sevenDay

    public var shortLabel: String { self == .fiveHour ? "5h" : "7d" }
    public var longLabel: String { self == .fiveHour ? "5-hour" : "Weekly" }

    /// Nominal window length, and — for both kinds — the exact width of the period a chart
    /// of that window should span.
    ///
    /// This used to carry the claim that the 5-hour window is *rolling*, with `resets_at`
    /// drifting forward as usage ages out. That is not what the API returns. Across 153
    /// consecutive polls covering 24 hours, `five_hour`'s reset instant took exactly five
    /// distinct values — 18:20, 23:20, 04:20, 13:20, 18:20 — each held constant for its whole
    /// cycle to within the sub-second jitter of the ISO parse, then stepped by exactly 18000s
    /// at turnover (32400s across an idle stretch, where the next block opened late). It is a
    /// fixed five-hour block anchored at first use after the previous one closed, so
    /// `resetsAt - nominalDuration` is when the period opened.
    ///
    /// Should some other plan genuinely roll, that same arithmetic still names the instant the
    /// oldest usage still being counted was spent — the lifetime of the window's current
    /// contents — so nothing downstream depends on settling which reading applies.
    public var nominalDuration: TimeInterval {
        self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600
    }

    /// The period a chart should span: from when this window opened to when it resets.
    ///
    /// Replaces the trailing `[now - nominalDuration, now]` the chart used to draw, which was
    /// a lookback rather than a period and was measurably wrong — at 16:08 on 30 July the
    /// 5-hour chart spanned 6.93 hours of wall clock under a heading that said "Last 5 hours",
    /// because it reached back across a turnover into the previous block.
    ///
    /// Every branch returns `start < end`, so the caller can build `start...end` without
    /// `ClosedRange` trapping on an inverted domain.
    public func chartPeriod(resetsAt: Date?, now: Date) -> (start: Date, end: Date) {
        if let resetsAt, resetsAt.timeIntervalSince1970.isFinite {
            // The ordinary case: the period is open, so it opened one duration before it closes.
            if resetsAt > now, resetsAt <= now.addingTimeInterval(nominalDuration) {
                return (resetsAt.addingTimeInterval(-nominalDuration), resetsAt)
            }
            // The window turned over and no poll has noticed yet — up to five minutes under
            // backoff, and four or five times a day. The period being drawn is the new one.
            if resetsAt <= now, resetsAt > now.addingTimeInterval(-nominalDuration) {
                return (resetsAt, resetsAt.addingTimeInterval(nominalDuration))
            }
        }
        // No reset instant, a non-finite one, or one further out than a whole window — this
        // account's own store contains a 5-hour reset reported 9h09m out, which anchored on
        // would put the entire domain in the future and drop every sample the chart has.
        return (now.addingTimeInterval(-nominalDuration), now)
    }
}

// MARK: - Poll samples (the burn-rate dataset)

/// One persisted observation of the limit percentages. Written once per
/// successful poll; the series of these is what burn rate is measured from.
public struct Sample: Codable, Sendable, Equatable {
    public let t: Date
    public let fiveHourPct: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayPct: Double?
    public let sevenDayResetsAt: Date?

    public init(
        t: Date, fiveHourPct: Double?, fiveHourResetsAt: Date?,
        sevenDayPct: Double?, sevenDayResetsAt: Date?
    ) {
        self.t = t
        self.fiveHourPct = fiveHourPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPct = sevenDayPct
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    public init(snapshot: UsageSnapshot) {
        self.t = snapshot.fetchedAt
        self.fiveHourPct = snapshot.fiveHour?.utilization
        self.fiveHourResetsAt = snapshot.fiveHour?.resetsAt
        self.sevenDayPct = snapshot.sevenDay?.utilization
        self.sevenDayResetsAt = snapshot.sevenDay?.resetsAt
    }

    public func percent(for kind: WindowKind) -> Double? {
        kind == .fiveHour ? fiveHourPct : sevenDayPct
    }

    public func resetsAt(for kind: WindowKind) -> Date? {
        kind == .fiveHour ? fiveHourResetsAt : sevenDayResetsAt
    }
}

// MARK: - Transcript events

/// Token counts for a single assistant message.
///
/// `cacheCreate5m` + `cacheCreate1h` normally sum to `cacheCreate`, but the
/// transcripts are not guaranteed to be internally consistent, so all three are
/// carried and the split is only used for cost estimation.
public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheCreate: Int
    public var cacheRead: Int
    public var cacheCreate5m: Int
    public var cacheCreate1h: Int

    public init(
        input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0,
        cacheCreate5m: Int = 0, cacheCreate1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
    }

    public static let zero = TokenCounts()

    /// Every token the request touched — the denominator for cache-hit ratio.
    public var total: Int { input + output + cacheCreate + cacheRead }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheCreate: a.cacheCreate + b.cacheCreate,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheCreate5m: a.cacheCreate5m + b.cacheCreate5m,
            cacheCreate1h: a.cacheCreate1h + b.cacheCreate1h
        )
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Element-wise maximum. Used when the same `(requestId, message.id)` shows up
    /// more than once: identical repeats are a no-op, and partial/streamed repeats
    /// resolve to the complete value rather than double-counting.
    public func maxed(with other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheCreate: max(cacheCreate, other.cacheCreate),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheCreate5m: max(cacheCreate5m, other.cacheCreate5m),
            cacheCreate1h: max(cacheCreate1h, other.cacheCreate1h)
        )
    }
}

/// One deduplicated assistant response drawn from the local transcripts.
public struct UsageEvent: Codable, Sendable, Equatable {
    /// Dedup identity: `requestId` plus the assistant `message.id`. Either may be
    /// missing in odd rows, hence the composite string key.
    public let key: String
    public let timestamp: Date
    public let sessionId: String
    public let cwd: String
    public let model: String
    public let effort: String?
    public let isSidechain: Bool
    /// Present exactly when `isSidechain` is true — every sidechain row observed carried an
    /// `agentId`, and no other rows did. This is the lane identifier that agent-hours is
    /// summed over.
    public let agentId: String?
    public var tokens: TokenCounts

    public init(
        key: String, timestamp: Date, sessionId: String, cwd: String, model: String,
        effort: String?, isSidechain: Bool, agentId: String? = nil, tokens: TokenCounts
    ) {
        self.key = key
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.isSidechain = isSidechain
        self.agentId = agentId
        self.tokens = tokens
    }

    /// Last path component of `cwd`, used as the project label in the UI.
    public var projectName: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.isEmpty ? "—" : (trimmed as NSString).lastPathComponent
    }
}

// MARK: - Aggregates

public struct SessionStat: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let projectName: String
    public let start: Date
    public let end: Date
    public let messageCount: Int
    public let tokens: TokenCounts
    public let models: [String]
    public let costEquivalent: Double

    public var id: String { sessionId }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Share of all input-side tokens that were served from cache. Excludes
    /// output tokens, which are generated rather than read.
    public var cacheHitRatio: Double {
        let denominator = tokens.cacheRead + tokens.cacheCreate + tokens.input
        guard denominator > 0 else { return 0 }
        return Double(tokens.cacheRead) / Double(denominator)
    }

    public init(
        sessionId: String, projectName: String, start: Date, end: Date, messageCount: Int,
        tokens: TokenCounts, models: [String], costEquivalent: Double
    ) {
        self.sessionId = sessionId
        self.projectName = projectName
        self.start = start
        self.end = end
        self.messageCount = messageCount
        self.tokens = tokens
        self.models = models
        self.costEquivalent = costEquivalent
    }
}

public struct DailyStat: Sendable, Equatable, Identifiable {
    public let day: Date          // start of day, local calendar
    public let tokens: TokenCounts
    public let costEquivalent: Double
    public let messageCount: Int

    public var id: Date { day }

    public init(day: Date, tokens: TokenCounts, costEquivalent: Double, messageCount: Int) {
        self.day = day
        self.tokens = tokens
        self.costEquivalent = costEquivalent
        self.messageCount = messageCount
    }
}

/// Time spent using Claude, in two readings that answer different questions.
///
/// There are no duration fields in the transcripts — verified by scanning every key matching
/// `dur|elapsed|ms$|latency|time|start|end` across a transcript corpus — so wall-clock time is
/// inferred by clustering message timestamps, and the gap that ends a stretch is a user setting.
public struct UsageHours: Sendable, Equatable {
    /// Union of active stretches across *all* sessions, so two projects worked concurrently
    /// count once. Depends on `gap`.
    public let wallClock: TimeInterval
    /// Sum of per-`agentId` spans (last message − first). Needs no gap rule: sub-agents run
    /// continuously from spawn to completion. 20 agents for 30 minutes is 10 agent-hours.
    public let agentTotal: TimeInterval
    /// Sum of per-session spans, *not* unioned — exceeds `wallClock` when sessions overlap.
    public let sessionTotal: TimeInterval
    /// The idle gap that was used to cluster. Echoed back so the UI can label the figure.
    public let gap: TimeInterval
    public let agentCount: Int

    public init(
        wallClock: TimeInterval, agentTotal: TimeInterval, sessionTotal: TimeInterval,
        gap: TimeInterval, agentCount: Int
    ) {
        self.wallClock = wallClock
        self.agentTotal = agentTotal
        self.sessionTotal = sessionTotal
        self.gap = gap
        self.agentCount = agentCount
    }

    /// How much more work happened than clock time elapsed. 1.0 means strictly serial.
    public var amplification: Double {
        guard wallClock > 0 else { return 1 }
        return (wallClock + agentTotal) / wallClock
    }
}

/// Equivalent cost split by which side of the request the tokens were on.
///
/// Computed where the event timestamps still exist, because each field bills at a different
/// multiple of the model's input rate *and* the rate itself can change over time. Pricing an
/// already-pooled total at one date is what made an earlier version of the panel's breakdown stop
/// summing to the total beside it once an introductory rate lapsed.
public struct FieldCosts: Sendable, Equatable {
    public var input: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var output: Double

    public init(input: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, output: Double = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public static let zero = FieldCosts()

    /// Equal to the model's `costEquivalent` by construction — the same events, the same rates.
    public var total: Double { input + cacheRead + cacheWrite + output }

    public static func + (a: FieldCosts, b: FieldCosts) -> FieldCosts {
        FieldCosts(
            input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output)
    }

    public static func += (a: inout FieldCosts, b: FieldCosts) { a = a + b }
}

public struct ModelUsage: Sendable, Equatable, Identifiable {
    public let model: String
    public let tokens: TokenCounts
    public let messageCount: Int
    public let costEquivalent: Double
    /// `costEquivalent` broken out by field, priced at the same per-event rates.
    public let fieldCosts: FieldCosts

    public var id: String { model }

    /// Human-facing name: `claude-opus-4-8` reads as `Opus 4.8`.
    public var displayName: String { Self.displayName(for: model) }

    public static func displayName(for model: String) -> String {
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = parts.first else { return model }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst()
            .drop(while: { Int($0) == nil })   // strip date suffixes like `20251001`
            .prefix(while: { Int($0) != nil })
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    public init(
        model: String, tokens: TokenCounts, messageCount: Int, costEquivalent: Double,
        fieldCosts: FieldCosts = .zero
    ) {
        self.model = model
        self.tokens = tokens
        self.messageCount = messageCount
        self.costEquivalent = costEquivalent
        self.fieldCosts = fieldCosts
    }
}

public struct EffortUsage: Sendable, Equatable, Identifiable {
    /// `nil` for requests that carried no `effort` field at all.
    public let effort: String?
    public let messageCount: Int
    public let tokens: TokenCounts

    public var id: String { effort ?? "—" }

    public init(effort: String?, messageCount: Int, tokens: TokenCounts) {
        self.effort = effort
        self.messageCount = messageCount
        self.tokens = tokens
    }
}

// MARK: - Menu bar presentation

/// What the always-visible menu bar item renders. All four variants read the same computed
/// values, so this is a single switch rather than four code paths. The formatting lives in
/// `UsageCore` (see `MenuBarLabelText`) so it can be tested without SwiftUI.
public enum MenuBarFormat: String, Codable, Sendable, CaseIterable {
    /// `42% → 63%` — utilization now and projected at reset. Default.
    case percentAndPace
    /// `42%`
    case percent
    /// `42% · 2h41m`
    case percentAndTimeLeft
    /// Ring only, no text.
    case iconOnly

    public var settingsLabel: String {
        switch self {
        case .percentAndPace: "42% → 63%   (now and projected)"
        case .percent: "42%   (just the percentage)"
        case .percentAndTimeLeft: "42% · 2h41m   (percentage and time to reset)"
        case .iconOnly: "Icon only"
        }
    }
}

// MARK: - Projection

/// Where the burn rate came from. Surfaced in the UI so a calibrated estimate is
/// never mistaken for a measured one.
public enum ProjectionBasis: String, Sendable {
    /// Fitted from the persisted poll series — the trustworthy path.
    case measured
    /// Derived from transcript token velocity calibrated against the current
    /// utilization, used before enough samples have accumulated.
    case estimated
    /// The window's own consumption divided by how long it has been open, carried
    /// forward at that average. Used for the fixed weekly window, whose horizon is
    /// far too long to extrapolate a regression across. Needs no poll history, so it
    /// is available from the first reading.
    case paced
}

public struct Projection: Sendable, Equatable {
    public let kind: WindowKind
    public let basis: ProjectionBasis
    /// Percentage points per hour. Negative means usage is aging out faster than
    /// it is accruing.
    public let percentPerHour: Double
    public let currentPercent: Double
    /// When utilization would reach 100% at the current rate. `nil` when the rate
    /// is flat or negative, or when the cap is further out than the window reset.
    public let timeToCap: Date?
    /// Projected utilization at the window's reset time. `nil` when the fit is too
    /// noisy to be worth showing.
    public let projectedAtReset: Double?
    /// Half-width of the confidence band on `projectedAtReset`, in percentage points.
    public let projectedBand: Double?
    public let resetsAt: Date?
    public let sampleCount: Int

    public init(
        kind: WindowKind, basis: ProjectionBasis, percentPerHour: Double,
        currentPercent: Double, timeToCap: Date?, projectedAtReset: Double?,
        projectedBand: Double?, resetsAt: Date?, sampleCount: Int
    ) {
        self.kind = kind
        self.basis = basis
        self.percentPerHour = percentPerHour
        self.currentPercent = currentPercent
        self.timeToCap = timeToCap
        self.projectedAtReset = projectedAtReset
        self.projectedBand = projectedBand
        self.resetsAt = resetsAt
        self.sampleCount = sampleCount
    }

    /// The interval's endpoints, so the text row and the chart's cone cannot disagree about
    /// where the forecast's uncertainty actually reaches.
    ///
    /// Asymmetric on purpose for the weekly window. That window is fixed — all 153 stored
    /// samples report the same `sevenDayResetsAt` to within a second, and utilization never
    /// once fell across them — so within a cycle it can only climb, and a lower end below the
    /// current reading is a claim the week will *un-consume* usage. Taken raw the live band
    /// put that end at 0.2% on a window reading 35%, and `SparklineView` drew it: a cone
    /// sloping down to the baseline under a window that cannot lose ground. The 5-hour window
    /// is not floored, because usage there really does age out.
    public var projectedLow: Double? {
        guard let projected = projectedAtReset, projected.isFinite,
            let band = projectedBand, band.isFinite, band >= 0
        else { return nil }
        let floor = (kind == .sevenDay && currentPercent.isFinite) ? max(0, currentPercent) : 0
        // Clamped back under `projected` so the interval can never invert on its way to a
        // string or a mark, whatever the floor and the band do relative to each other.
        return min(max(projected - band, floor), projected)
    }

    /// Top of the interval, clamped to the same ceiling `clampedProjection` puts on the centre
    /// so a 1000-point band from a one-hour-old week cannot reach Swift Charts as geometry.
    public var projectedHigh: Double? {
        guard let projected = projectedAtReset, projected.isFinite,
            let band = projectedBand, band.isFinite, band >= 0
        else { return nil }
        return max(min(projected + band, ProjectionEngine.displayCeiling), projected)
    }

    /// True when usage is on pace to exhaust the window before it resets.
    public var willCapEarly: Bool {
        guard let cap = timeToCap, let reset = resetsAt else { return false }
        return cap < reset
    }
}

// MARK: - Overall app state

public enum DataHealth: Sendable, Equatable {
    case live
    /// Serving a cached snapshot; the last poll failed.
    case offline(since: Date, reason: String)
    /// Credentials are present but expired, and no refreshed token has appeared.
    case staleCredentials
    /// No usable credentials found in the Keychain at all.
    case noCredentials
}
