import Foundation

/// Rollups over the deduplicated transcript events.
///
/// Every entry point is a pure function of its arguments, so the UI can recompute whole panels
/// on each refresh instead of maintaining incremental state. Where an "as-of" `now` is passed —
/// `sessions`, `daily`, `modelSplit` — events timestamped after it are ignored: a transcript
/// written by a machine with a skewed clock must not leak into "today" or inflate a session that
/// has already ended. `usageHours`, `effortSplit`, `tokens` and `cacheHitRatio` take no `now`
/// (the contract gives them none) and so count every event they are handed.
///
/// Events are expected to arrive from `TranscriptScanner`, which has already dropped
/// `<synthetic>` rows and collapsed duplicate `(requestId, message.id)` pairs — these
/// functions deliberately do no filtering of their own so that what is counted here is
/// exactly what the scanner reports.
public enum Aggregates {
    /// Idle time that ends an active stretch. The transcripts carry no duration fields, so
    /// "time spent" is always an inference from timestamp spacing and this constant is the
    /// single knob behind that inference; it is a user setting in the UI.
    public static let defaultActiveGap: TimeInterval = 10 * 60

    // MARK: - Sessions

    /// Sessions ordered most-recent-first, split wherever the pause between consecutive
    /// messages exceeds `idleGap` — a transcript session id can span days of on-and-off work,
    /// which would otherwise report a 14-hour "session".
    public static func sessions(
        from events: [UsageEvent], idleGap: TimeInterval, now: Date
    ) -> [SessionStat] {
        var grouped: [String: [UsageEvent]] = [:]
        for event in events where event.timestamp <= now {
            grouped[event.sessionId, default: []].append(event)
        }

        var stats: [SessionStat] = []
        for (sessionId, group) in grouped {
            let segments = split(group.sorted { $0.timestamp < $1.timestamp }, idleGap: idleGap)
            for (index, segment) in segments.enumerated() {
                // The earliest segment keeps the raw transcript id and only later ones are
                // suffixed, so a segment's `Identifiable` id does not change when a subsequent
                // poll appends a new segment to the same transcript session — suffixing every
                // segment would renumber the existing row from `id` to `id#1` and make SwiftUI
                // tear it down and rebuild it.
                stats.append(
                    summarise(segment, sessionId: index == 0 ? sessionId : "\(sessionId)#\(index + 1)")
                )
            }
        }

        return stats.sorted { lhs, rhs in
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.sessionId < rhs.sessionId
        }
    }

    /// Splits an ascending run of events wherever the pause exceeds `idleGap`.
    private static func split(_ ordered: [UsageEvent], idleGap: TimeInterval) -> [[UsageEvent]] {
        var segments: [[UsageEvent]] = []
        var current: [UsageEvent] = []
        for event in ordered {
            if let previous = current.last,
                event.timestamp.timeIntervalSince(previous.timestamp) > idleGap
            {
                segments.append(current)
                current = []
            }
            current.append(event)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// `segment` must be non-empty and ascending by timestamp.
    private static func summarise(_ segment: [UsageEvent], sessionId: String) -> SessionStat {
        var tokens = TokenCounts.zero
        var cost = 0.0
        var tokensByModel: [String: Int] = [:]
        for event in segment {
            tokens += event.tokens
            // Priced at the moment the tokens were spent, so a session that predates the end
            // of Sonnet 5's introductory window keeps the rate that was in force then.
            cost += Pricing.cost(event.tokens, model: event.model, on: event.timestamp)
            tokensByModel[event.model, default: 0] += event.tokens.total
        }
        let models = tokensByModel.keys.sorted { lhs, rhs in
            let left = tokensByModel[lhs] ?? 0
            let right = tokensByModel[rhs] ?? 0
            return left == right ? lhs < rhs : left > right
        }
        let start = segment.first?.timestamp ?? Date(timeIntervalSince1970: 0)
        let end = segment.last?.timestamp ?? start
        return SessionStat(
            sessionId: sessionId,
            projectName: segment.first?.projectName ?? "—",
            start: start,
            end: end,
            messageCount: segment.count,
            tokens: tokens,
            models: models,
            costEquivalent: cost)
    }

    // MARK: - Days

    /// The last `days` days inclusive of today, ascending, zero-filled so a chart has a bar for
    /// every day. Bucketing uses `calendar`, not UTC: a message sent at 23:00 local belongs to
    /// that local day even though its timestamp is the next day in UTC.
    public static func daily(
        from events: [UsageEvent], days: Int, calendar: Calendar, now: Date
    ) -> [DailyStat] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var buckets: [Date] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            buckets.append(calendar.startOfDay(for: day))
        }
        guard let earliest = buckets.first else { return [] }

        var tokens: [Date: TokenCounts] = [:]
        var counts: [Date: Int] = [:]
        var costs: [Date: Double] = [:]
        for event in events where event.timestamp >= earliest && event.timestamp <= now {
            let day = calendar.startOfDay(for: event.timestamp)
            tokens[day, default: .zero] += event.tokens
            counts[day, default: 0] += 1
            costs[day, default: 0] += Pricing.cost(
                event.tokens, model: event.model, on: event.timestamp)
        }

        return buckets.map { day in
            DailyStat(
                day: day,
                tokens: tokens[day] ?? .zero,
                costEquivalent: costs[day] ?? 0,
                messageCount: counts[day] ?? 0)
        }
    }

    // MARK: - Time spent

    /// Time spent, in the two readings `UsageHours` documents.
    ///
    /// `wallClock` unions active stretches across *all* sessions before summing, so two
    /// projects worked at the same time count once — this is clock time, and clock time cannot
    /// be double-spent. `sessionTotal` runs the same clustering per session and sums without
    /// unioning, so it exceeds `wallClock` exactly when sessions overlapped. Agent hours use no
    /// gap rule at all: a sub-agent runs continuously from spawn to completion, so its span is
    /// simply last − first.
    public static func usageHours(from events: [UsageEvent], gap: TimeInterval) -> UsageHours {
        var perSession: [String: [Date]] = [:]
        var perAgent: [String: (first: Date, last: Date)] = [:]
        var all: [Date] = []
        all.reserveCapacity(events.count)

        for event in events {
            all.append(event.timestamp)
            perSession[event.sessionId, default: []].append(event.timestamp)
            guard let agent = event.agentId else { continue }
            if let span = perAgent[agent] {
                perAgent[agent] = (
                    min(span.first, event.timestamp), max(span.last, event.timestamp)
                )
            } else {
                perAgent[agent] = (event.timestamp, event.timestamp)
            }
        }

        let sessionTotal = perSession.values.reduce(0.0) { $0 + activeDuration($1, gap: gap) }
        let agentTotal = perAgent.values.reduce(0.0) { $0 + $1.last.timeIntervalSince($1.first) }

        return UsageHours(
            wallClock: activeDuration(all, gap: gap),
            agentTotal: agentTotal,
            sessionTotal: sessionTotal,
            gap: gap,
            agentCount: perAgent.count)
    }

    /// Sum of stretch spans, where a stretch ends when the next timestamp is more than `gap`
    /// later. A lone timestamp is a zero-length stretch — one message is a moment, not a session.
    private static func activeDuration(_ timestamps: [Date], gap: TimeInterval) -> TimeInterval {
        let ordered = timestamps.sorted()
        guard let first = ordered.first else { return 0 }
        var total: TimeInterval = 0
        var stretchStart = first
        var previous = first
        for timestamp in ordered.dropFirst() {
            if timestamp.timeIntervalSince(previous) > gap {
                total += previous.timeIntervalSince(stretchStart)
                stretchStart = timestamp
            }
            previous = timestamp
        }
        return total + previous.timeIntervalSince(stretchStart)
    }

    // MARK: - Splits

    /// Per-model totals, heaviest first by token count.
    public static func modelSplit(from events: [UsageEvent], now: Date) -> [ModelUsage] {
        var tokens: [String: TokenCounts] = [:]
        var counts: [String: Int] = [:]
        var costs: [String: Double] = [:]
        for event in events where event.timestamp <= now {
            tokens[event.model, default: .zero] += event.tokens
            counts[event.model, default: 0] += 1
            costs[event.model, default: 0] += Pricing.cost(
                event.tokens, model: event.model, on: event.timestamp)
        }
        return tokens.map { model, counted in
            ModelUsage(
                model: model,
                tokens: counted,
                messageCount: counts[model] ?? 0,
                costEquivalent: costs[model] ?? 0)
        }
        .sorted { lhs, rhs in
            if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
            return lhs.model < rhs.model
        }
    }

    /// Per-effort totals. Requests that carried no `effort` field form their own bucket keyed by
    /// `nil` rather than being folded into a default level — "unset" is not an effort setting.
    public static func effortSplit(from events: [UsageEvent]) -> [EffortUsage] {
        var tokens: [String?: TokenCounts] = [:]
        var counts: [String?: Int] = [:]
        for event in events {
            tokens[event.effort, default: .zero] += event.tokens
            counts[event.effort, default: 0] += 1
        }
        return tokens.map { effort, counted in
            EffortUsage(effort: effort, messageCount: counts[effort] ?? 0, tokens: counted)
        }
        .sorted { lhs, rhs in
            if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
            switch (lhs.effort, rhs.effort) {
            case let (.some(left), .some(right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
    }

    // MARK: - Totals

    /// Token total over events at or after `since`.
    public static func tokens(from events: [UsageEvent], since: Date) -> TokenCounts {
        var total = TokenCounts.zero
        for event in events where event.timestamp >= since { total += event.tokens }
        return total
    }

    /// Share of the input side served from cache: `cacheRead / (cacheRead + cacheCreate + input)`.
    /// Output tokens are excluded because they are generated, never read from a cache, and
    /// including them would make the ratio a function of response length.
    public static func cacheHitRatio(from events: [UsageEvent]) -> Double {
        var read = 0
        var denominator = 0
        for event in events {
            read += event.tokens.cacheRead
            denominator += event.tokens.cacheRead + event.tokens.cacheCreate + event.tokens.input
        }
        guard denominator > 0 else { return 0 }
        return Double(read) / Double(denominator)
    }
}

// MARK: - Segmented session ids

extension SessionStat {
    /// The transcript session id with any segment suffix removed.
    ///
    /// `Aggregates.sessions(from:idleGap:now:)` splits one transcript session into several
    /// stats when work paused, and `SessionStat.id` is `sessionId`, so segments after the first
    /// carry a `#n` suffix to keep ids unique for SwiftUI lists. Use this to get back to the id
    /// that appears in the transcripts.
    public var baseSessionId: String {
        guard let marker = sessionId.lastIndex(of: "#") else { return sessionId }
        let suffix = sessionId[sessionId.index(after: marker)...]
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return sessionId }
        return String(sessionId[..<marker])
    }
}
