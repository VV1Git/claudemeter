import Foundation
import Testing

import UsageCore

// `Aggregates` is a pure function of its arguments — it opens no files, so these tests need no
// `Paths` override and touch neither the real `~/.claude` nor the app support directory.

// MARK: - Helpers

private func makeEvent(
    at timestamp: Date,
    session: String = "session-a",
    cwd: String = "/Users/tester/Projects/claudemeter",
    model: String = "claude-opus-5",
    effort: String? = nil,
    agent: String? = nil,
    tokens: TokenCounts = TokenCounts(input: 100)
) -> UsageEvent {
    UsageEvent(
        key: "\(session)|\(agent ?? "-")|\(timestamp.timeIntervalSince1970)",
        timestamp: timestamp,
        sessionId: session,
        cwd: cwd,
        model: model,
        effort: effort,
        isSidechain: agent != nil,
        agentId: agent,
        tokens: tokens)
}

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

private func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func calendar(_ timeZone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    return calendar
}

private func newYorkCalendar() throws -> Calendar { try calendar("America/New_York") }

// MARK: - Sessions

@Test func sessionsSplitWhenThePauseExceedsTheIdleGap() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0),
        makeEvent(at: t0 + minutes(5)),
        makeEvent(at: t0 + minutes(25)),
    ]
    let now = t0 + minutes(60)

    let split = Aggregates.sessions(from: events, idleGap: minutes(10), now: now)
    #expect(split.count == 2)
    #expect(split.map(\.messageCount).sorted() == [1, 2])
    #expect(split.allSatisfy { $0.baseSessionId == "session-a" })
    // `SessionStat.id` is `sessionId`, so the segments must not collide. The earliest segment
    // keeps the raw id: a later poll that appends a new segment must not renumber the row that
    // was already on screen.
    #expect(Set(split.map(\.sessionId)) == ["session-a", "session-a#2"])
    #expect(split.first?.sessionId == "session-a#2")  // most recent first

    let whole = Aggregates.sessions(from: events, idleGap: minutes(30), now: now)
    #expect(whole.count == 1)
    #expect(whole.first?.sessionId == "session-a")
    #expect(whole.first?.messageCount == 3)
    #expect(isClose(whole.first?.duration ?? 0, minutes(25)))
}

@Test func sessionsAreOrderedMostRecentFirstAndIgnoreFutureEvents() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0, session: "older"),
        makeEvent(at: t0 + minutes(2), session: "older"),
        makeEvent(at: t0 + minutes(30), session: "newer"),
        makeEvent(at: t0 + minutes(600), session: "from-the-future"),
    ]

    let result = Aggregates.sessions(from: events, idleGap: minutes(10), now: t0 + minutes(60))
    #expect(result.map(\.sessionId) == ["newer", "older"])
    #expect(result.first?.projectName == "claudemeter")
}

@Test func sessionSummaryTotalsTokensModelsAndCost() throws {
    let t0 = try #require(ISO8601.date(from: "2026-09-15T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0, model: "claude-opus-5", tokens: TokenCounts(input: 1_000_000)),
        makeEvent(
            at: t0 + minutes(1), model: "claude-sonnet-5",
            tokens: TokenCounts(input: 100, output: 900, cacheRead: 9_000)),
    ]

    let result = Aggregates.sessions(from: events, idleGap: minutes(10), now: t0 + minutes(10))
    let session = try #require(result.first)
    #expect(session.messageCount == 2)
    #expect(session.tokens.input == 1_000_100)
    #expect(session.tokens.output == 900)
    #expect(session.tokens.cacheRead == 9_000)
    // Heaviest model first: the Opus request carries a million tokens, Sonnet ~10k.
    #expect(session.models == ["claude-opus-5", "claude-sonnet-5"])
    // 1M Opus input = $5.00, plus a negligible Sonnet remainder.
    #expect(session.costEquivalent > 5.0)
    #expect(session.costEquivalent < 5.1)
    #expect(isClose(session.cacheHitRatio, 9_000.0 / (9_000.0 + 1_000_100.0)))
}

// MARK: - Usage hours

@Test func usageHoursUnionOverlappingSessionsButSessionTotalDoesNot() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    var events: [UsageEvent] = []
    for step in stride(from: 0.0, through: 60.0, by: 5.0) {
        events.append(makeEvent(at: t0 + minutes(step), session: "project-a"))
    }
    for step in stride(from: 30.0, through: 90.0, by: 5.0) {
        events.append(makeEvent(at: t0 + minutes(step), session: "project-b"))
    }

    let hours = Aggregates.usageHours(from: events, gap: Aggregates.defaultActiveGap)
    // Concurrent work counts once: the union spans t0 → t0+90m.
    #expect(isClose(hours.wallClock, minutes(90)))
    // Summing sessions independently double-counts the 30 minutes they overlapped.
    #expect(isClose(hours.sessionTotal, minutes(120)))
    #expect(hours.sessionTotal > hours.wallClock)
    #expect(isClose(hours.gap, Aggregates.defaultActiveGap))
    #expect(hours.agentCount == 0)
    #expect(hours.agentTotal == 0)
}

@Test func wideningTheGapBridgesAPauseIntoOneStretch() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0),
        makeEvent(at: t0 + minutes(5)),
        makeEvent(at: t0 + minutes(12)),  // seven minutes after the previous message
        makeEvent(at: t0 + minutes(17)),
    ]

    let tight = Aggregates.usageHours(from: events, gap: minutes(5))
    #expect(isClose(tight.wallClock, minutes(10)))

    let loose = Aggregates.usageHours(from: events, gap: minutes(10))
    #expect(isClose(loose.wallClock, minutes(17)))
}

@Test func concurrentAgentsSumToAgentHoursRegardlessOfGap() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    var events: [UsageEvent] = []
    for agent in ["agent-1", "agent-2", "agent-3"] {
        events.append(makeEvent(at: t0, agent: agent))
        events.append(makeEvent(at: t0 + minutes(30), agent: agent))
    }

    // Three agents, thirty minutes each, all at the same time: 1.5 agent-hours. A zero gap is
    // included because it is the value at which wall-clock clustering collapses entirely — agent
    // hours must be untouched by it, since they are computed without any gap rule.
    for gap in [0, minutes(1), minutes(10), minutes(60)] {
        let hours = Aggregates.usageHours(from: events, gap: gap)
        #expect(isClose(hours.agentTotal, 1.5 * 3600))
        #expect(hours.agentCount == 3)
    }

    // Wall clock, unlike agent hours, does depend on the gap.
    #expect(isClose(Aggregates.usageHours(from: events, gap: minutes(1)).wallClock, 0))
    #expect(isClose(Aggregates.usageHours(from: events, gap: minutes(60)).wallClock, minutes(30)))
}

@Test func agentWithASingleEventContributesNoTime() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let hours = Aggregates.usageHours(
        from: [makeEvent(at: t0, agent: "one-shot")], gap: Aggregates.defaultActiveGap)
    #expect(hours.agentCount == 1)
    #expect(hours.agentTotal == 0)
    #expect(hours.wallClock == 0)
    #expect(hours.sessionTotal == 0)
    #expect(hours.amplification == 1)
}

@Test func theMergeSortsBeforeItClustersSoInputOrderIsIrrelevant() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    // Two five-minute stretches either side of a 25-minute idle hole.
    let ordered = [
        makeEvent(at: t0), makeEvent(at: t0 + minutes(5)),
        makeEvent(at: t0 + minutes(30)), makeEvent(at: t0 + minutes(35)),
    ]
    let jumbled = [ordered[2], ordered[0], ordered[3], ordered[1]]

    let straight = Aggregates.usageHours(from: ordered, gap: minutes(10))
    let shuffled = Aggregates.usageHours(from: jumbled, gap: minutes(10))
    #expect(isClose(straight.wallClock, minutes(10)))
    #expect(isClose(shuffled.wallClock, straight.wallClock))
    // `sessionTotal` sums per-session *stretch* durations, so the idle hole is excluded there too
    // — it is not the raw first-to-last span of the session.
    #expect(isClose(shuffled.sessionTotal, minutes(10)))

    let agentEvents = [
        makeEvent(at: t0 + minutes(30), agent: "a"),
        makeEvent(at: t0, agent: "a"),
        makeEvent(at: t0 + minutes(10), agent: "a"),
    ]
    #expect(
        isClose(Aggregates.usageHours(from: agentEvents, gap: minutes(1)).agentTotal, minutes(30)))
}

@Test func aPauseExactlyEqualToTheGapDoesNotSplit() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let now = t0 + minutes(60)

    // Exactly `gap` apart is still one stretch — the threshold is exclusive, so a user whose
    // idle gap is 10 minutes does not lose a stretch to a pause of precisely 10 minutes.
    let touching = [makeEvent(at: t0), makeEvent(at: t0 + minutes(10))]
    #expect(isClose(Aggregates.usageHours(from: touching, gap: minutes(10)).wallClock, minutes(10)))
    #expect(Aggregates.sessions(from: touching, idleGap: minutes(10), now: now).count == 1)

    // One second past the threshold does split, leaving two zero-length stretches.
    let past = [makeEvent(at: t0), makeEvent(at: t0 + minutes(10) + 1)]
    #expect(Aggregates.usageHours(from: past, gap: minutes(10)).wallClock == 0)
    #expect(Aggregates.sessions(from: past, idleGap: minutes(10), now: now).count == 2)
}

@Test func agentHoursIgnoreIdleGapsWithinOneAgent() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0, agent: "long-runner"),
        makeEvent(at: t0 + minutes(120), agent: "long-runner"),
    ]

    // No gap clustering for agents: a sub-agent runs from spawn to completion, so a quiet
    // stretch in the middle is still time the agent was working.
    let hours = Aggregates.usageHours(from: events, gap: minutes(1))
    #expect(isClose(hours.agentTotal, minutes(120)))
    // Wall clock, which does cluster, sees only two isolated moments.
    #expect(hours.wallClock == 0)
}

@Test func sessionTotalEqualsTheSummedDurationsOfTheSessionsList() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    var events: [UsageEvent] = []
    for step in stride(from: 0.0, through: 60.0, by: 5.0) {
        events.append(makeEvent(at: t0 + minutes(step), session: "project-a"))
    }
    for step in stride(from: 30.0, through: 90.0, by: 5.0) {
        events.append(makeEvent(at: t0 + minutes(step), session: "project-b"))
    }
    events.append(makeEvent(at: t0 + minutes(200), session: "project-a"))  // isolated: zero-length
    events.append(makeEvent(at: t0 + minutes(240), session: "project-b"))
    events.append(makeEvent(at: t0 + minutes(245), session: "project-b"))

    // `sessions` and `usageHours` infer active time from the same clustering rule, so they must
    // never disagree: `sessionTotal` is by definition the sum of the rows the sessions list shows.
    // Only `wallClock` unions, and it is the smaller figure precisely because the two projects
    // overlapped for half an hour — that difference is what `amplification` reports.
    let hours = Aggregates.usageHours(from: events, gap: Aggregates.defaultActiveGap)
    let listed = Aggregates.sessions(
        from: events, idleGap: Aggregates.defaultActiveGap, now: t0 + minutes(1_000))
    #expect(isClose(listed.reduce(0) { $0 + $1.duration }, hours.sessionTotal))
    #expect(isClose(hours.sessionTotal, minutes(125)))
    #expect(isClose(hours.wallClock, minutes(95)))
}

@Test func usageHoursOfNothingIsZero() {
    let hours = Aggregates.usageHours(from: [], gap: Aggregates.defaultActiveGap)
    #expect(hours.wallClock == 0)
    #expect(hours.agentTotal == 0)
    #expect(hours.sessionTotal == 0)
    #expect(hours.agentCount == 0)
}

// MARK: - Daily

@Test func dailyZeroFillsAGapDayAndBucketsByTheLocalCalendar() throws {
    let calendar = try newYorkCalendar()
    let now = try #require(ISO8601.date(from: "2026-07-29T16:00:00.000Z"))  // noon EDT, Jul 29
    let lateOnTheTwentySeventh = try #require(ISO8601.date(from: "2026-07-28T03:00:00.000Z"))
    let events = [
        makeEvent(
            at: try #require(ISO8601.date(from: "2026-07-20T12:00:00.000Z")),
            tokens: TokenCounts(input: 42)),  // older than the window
        makeEvent(at: try #require(ISO8601.date(from: "2026-07-27T18:00:00.000Z"))),
        makeEvent(at: lateOnTheTwentySeventh),  // 23:00 EDT on the 27th, not the 28th in UTC
        makeEvent(at: try #require(ISO8601.date(from: "2026-07-29T15:00:00.000Z")),
                  tokens: TokenCounts(input: 1_000_000)),
    ]

    let result = Aggregates.daily(from: events, days: 3, calendar: calendar, now: now)
    #expect(result.count == 3)
    #expect(result.map(\.day) == result.map(\.day).sorted())
    #expect(result[0].day == calendar.startOfDay(for: lateOnTheTwentySeventh))
    #expect(result[2].day == calendar.startOfDay(for: now))

    #expect(result[0].messageCount == 2)
    #expect(result[0].tokens.input == 200)

    #expect(result[1].messageCount == 0)
    #expect(result[1].tokens == TokenCounts.zero)
    #expect(result[1].costEquivalent == 0)

    #expect(result[2].messageCount == 1)
    #expect(result[2].tokens.input == 1_000_000)
    #expect(isClose(result[2].costEquivalent, 5.0))  // 1M Opus 5 input tokens at $5/MTok
}

@Test func dailyBucketsAcrossADaylightSavingTransitionWithoutLosingADay() throws {
    let calendar = try newYorkCalendar()
    let now = try #require(ISO8601.date(from: "2026-11-02T17:00:00.000Z"))  // noon EST, Nov 2
    // Nov 1 2026 is a 25-hour day in New York: 01:00–02:00 local happens twice, so two distinct
    // instants share the wall clock `01:30`. Both belong to Nov 1, and the extra hour must not
    // push the window's earliest bucket off by a day.
    let lateOnOctober31 = try #require(ISO8601.date(from: "2026-11-01T03:00:00.000Z"))
    let firstOneThirty = try #require(ISO8601.date(from: "2026-11-01T05:30:00.000Z"))  // EDT
    let secondOneThirty = try #require(ISO8601.date(from: "2026-11-01T06:30:00.000Z"))  // EST
    let lateOnNovember1 = try #require(ISO8601.date(from: "2026-11-02T03:00:00.000Z"))
    let events = [
        makeEvent(at: lateOnOctober31), makeEvent(at: firstOneThirty),
        makeEvent(at: secondOneThirty), makeEvent(at: lateOnNovember1), makeEvent(at: now),
    ]

    let result = Aggregates.daily(from: events, days: 3, calendar: calendar, now: now)
    #expect(Set(result.map(\.day)).count == 3)  // no bucket collapsed into its neighbour
    #expect(result.map(\.day) == result.map(\.day).sorted())
    #expect(result.last?.day == calendar.startOfDay(for: now))
    #expect(result.map(\.messageCount) == [1, 3, 1])
    #expect(result.reduce(0) { $0 + $1.messageCount } == events.count)
}

@Test func dailyCountsAnEventLandingExactlyOnTheEarliestBucketBoundary() throws {
    let calendar = try newYorkCalendar()
    let now = try #require(ISO8601.date(from: "2026-07-29T16:00:00.000Z"))
    let windowStart = calendar.startOfDay(
        for: try #require(ISO8601.date(from: "2026-07-27T12:00:00.000Z")))

    // The window is inclusive at its lower edge: midnight local on the earliest day is in range,
    // and the instant before it belongs to the previous day and must not be folded into bucket 0.
    let result = Aggregates.daily(
        from: [makeEvent(at: windowStart), makeEvent(at: windowStart - 0.001)],
        days: 3, calendar: calendar, now: now)
    #expect(result[0].messageCount == 1)
    #expect(result.reduce(0) { $0 + $1.messageCount } == 1)
}

@Test func dailyKeepsOneBucketPerDayInZonesWhoseDayStartsAtOneAM() throws {
    // Chile and Lebanon shift at local midnight, so `startOfDay` on the transition day is 01:00
    // rather than 00:00 — the case where naïve 86,400-second arithmetic duplicates or drops a day.
    for zone in ["America/Santiago", "Asia/Beirut", "Australia/Lord_Howe", "Pacific/Apia"] {
        let zoned = try calendar(zone)
        for stamp in [
            "2026-09-07T16:00:00.000Z", "2026-03-30T16:00:00.000Z", "2026-04-06T16:00:00.000Z",
            "2026-10-26T16:00:00.000Z",
        ] {
            let now = try #require(ISO8601.date(from: stamp))
            let result = Aggregates.daily(from: [], days: 5, calendar: zoned, now: now)
            #expect(result.count == 5)
            #expect(Set(result.map(\.day)).count == 5)
            #expect(result.map(\.day) == result.map(\.day).sorted())
            #expect(result.last?.day == zoned.startOfDay(for: now))
            #expect(result.allSatisfy { zoned.startOfDay(for: $0.day) == $0.day })
        }
    }
}

@Test func dailyWithNonPositiveDaysIsEmpty() throws {
    let calendar = try newYorkCalendar()
    let now = try #require(ISO8601.date(from: "2026-07-29T16:00:00.000Z"))
    #expect(Aggregates.daily(from: [makeEvent(at: now)], days: 0, calendar: calendar, now: now).isEmpty)
    #expect(Aggregates.daily(from: [], days: -3, calendar: calendar, now: now).isEmpty)
}

// MARK: - Splits and totals

@Test func modelSplitIsSortedByTokensAndCosted() throws {
    let t0 = try #require(ISO8601.date(from: "2026-09-15T12:00:00.000Z"))
    let events = [
        makeEvent(
            at: t0, model: "claude-haiku-4-5", tokens: TokenCounts(input: 100_000)),
        makeEvent(
            at: t0 + minutes(1), model: "claude-opus-5",
            tokens: TokenCounts(input: 1_000_000, output: 200_000)),
        makeEvent(
            at: t0 + minutes(2), model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000_000)),
        makeEvent(at: t0 + minutes(3), model: "claude-opus-5", tokens: TokenCounts(input: 0)),
    ]

    let split = Aggregates.modelSplit(from: events, now: t0 + minutes(10))
    #expect(split.map(\.model) == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"])
    #expect(split[0].messageCount == 2)
    #expect(split[0].tokens.total == 1_200_000)
    #expect(isClose(split[0].costEquivalent, 10.0))  // 1M in at $5 + 200k out at $25/MTok
    #expect(isClose(split[1].costEquivalent, 3.0))  // post-intro Sonnet 5 input rate
    #expect(isClose(split[2].costEquivalent, 0.1))
    #expect(split[0].displayName == "Opus 5")
}

@Test func effortSplitKeepsUnsetEffortInItsOwnBucket() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: t0, effort: "xhigh", tokens: TokenCounts(input: 500)),
        makeEvent(at: t0 + minutes(1), effort: "xhigh", tokens: TokenCounts(input: 500)),
        makeEvent(at: t0 + minutes(2), effort: "high", tokens: TokenCounts(input: 300)),
        makeEvent(at: t0 + minutes(3), effort: nil, tokens: TokenCounts(input: 100)),
        makeEvent(at: t0 + minutes(4), effort: nil, tokens: TokenCounts(input: 100)),
    ]

    let split = Aggregates.effortSplit(from: events)
    #expect(split.count == 3)
    #expect(split.map(\.effort) == ["xhigh", "high", nil])

    let unset = try #require(split.first { $0.effort == nil })
    #expect(unset.messageCount == 2)
    #expect(unset.tokens.input == 200)
    #expect(unset.id == "—")

    let xhigh = try #require(split.first { $0.effort == "xhigh" })
    #expect(xhigh.messageCount == 2)
    #expect(xhigh.tokens.input == 1_000)
}

@Test func tokensSinceIncludesTheBoundaryAndExcludesEarlierEvents() throws {
    let cutoff = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(at: cutoff - 1, tokens: TokenCounts(input: 1)),
        makeEvent(at: cutoff, tokens: TokenCounts(input: 10, output: 2)),
        makeEvent(at: cutoff + minutes(5), tokens: TokenCounts(input: 100, cacheRead: 7)),
    ]

    let total = Aggregates.tokens(from: events, since: cutoff)
    #expect(total.input == 110)
    #expect(total.output == 2)
    #expect(total.cacheRead == 7)
    #expect(Aggregates.tokens(from: events, since: cutoff + minutes(30)) == TokenCounts.zero)
}

@Test func cacheHitRatioIgnoresOutputTokens() throws {
    let t0 = try #require(ISO8601.date(from: "2026-07-29T12:00:00.000Z"))
    let events = [
        makeEvent(
            at: t0,
            tokens: TokenCounts(input: 100, output: 1_000_000, cacheCreate: 0, cacheRead: 900)),
        makeEvent(
            at: t0 + minutes(1),
            tokens: TokenCounts(input: 0, output: 500_000, cacheCreate: 0, cacheRead: 0)),
    ]

    // 900 read / (900 read + 0 created + 100 fresh input) — the million output tokens are
    // generated, not read, and must not move the ratio.
    #expect(isClose(Aggregates.cacheHitRatio(from: events), 0.9))
    #expect(Aggregates.cacheHitRatio(from: []) == 0)
    // Output-only events leave the input-side denominator at zero: return 0, do not divide.
    #expect(
        Aggregates.cacheHitRatio(from: [makeEvent(at: t0, tokens: TokenCounts(output: 5_000))]) == 0)
}

@Test func costsUseTheRateInForceWhenTheTokensWereSpent() throws {
    let july = try #require(ISO8601.date(from: "2026-07-15T12:00:00.000Z"))
    let september = try #require(ISO8601.date(from: "2026-09-15T12:00:00.000Z"))
    let events = [
        makeEvent(at: july, model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000_000)),
        makeEvent(at: september, model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000_000)),
    ]

    // Introductory pricing is a window over when the tokens were spent, not a property of the
    // report date: one Sonnet 5 bucket, $2/MTok inside the window and $3/MTok after it.
    let split = Aggregates.modelSplit(from: events, now: september + minutes(10))
    #expect(split.count == 1)
    #expect(isClose(split[0].costEquivalent, 5.0))

    let julyOnly = Aggregates.sessions(from: [events[0]], idleGap: minutes(10), now: september)
    #expect(isClose(try #require(julyOnly.first).costEquivalent, 2.0))
}
