import Foundation
import Testing

@testable import UsageCore

/// `calibrate` and the profile aggregates are pure over the samples and events handed to them,
/// so no `Paths` override is needed here.
struct CalibrationTests {

    private static let now = ISO8601.date(from: "2026-01-15T12:00:00Z")!

    private func event(
        _ key: String, at t: Date, output: Int, model: String = "claude-opus-5",
        isSidechain: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            key: key, timestamp: t, sessionId: "s", cwd: "/x", model: model, effort: nil,
            isSidechain: isSidechain, agentId: nil, tokens: TokenCounts(output: output))
    }

    /// `count` weekly samples ten minutes apart ending at `now`, rising by `step` each time.
    private func weeklySamples(
        count: Int, from start: Double, step: Double, resetsAt: Date, now: Date = CalibrationTests.now
    ) -> [Sample] {
        (0..<count).map { index in
            Sample(
                t: now.addingTimeInterval(-Double(count - 1 - index) * 600),
                fiveHourPct: nil, fiveHourResetsAt: nil,
                sevenDayPct: start + step * Double(index), sevenDayResetsAt: resetsAt)
        }
    }

    // MARK: - Exchange rate

    @Test("The exchange rate is the tokens spent over the points they bought")
    func exchangeRateIsTokensOverPoints() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        let samples = weeklySamples(count: 6, from: 10, step: 1, resetsAt: resetsAt)
        // One event in each of the five intervals. Output weighs 5×, so 200k output is 1Mw,
        // and one point is bought per interval.
        let events = (1..<6).map {
            event("e\($0)", at: Self.now.addingTimeInterval(-Double(6 - 1 - $0) * 600 - 60),
                output: 200_000)
        }

        let calibration = try #require(
            ProjectionEngine.calibrate(
                kind: .sevenDay, samples: samples, events: events, now: Self.now))

        #expect(calibration.intervals == 5)
        #expect(abs(calibration.pointsObserved - 5) < 1e-9)
        #expect(abs(calibration.weightedTokensPerPoint - 1_000_000) < 1)
        // 90 points of headroom at a million weighted tokens each.
        let headroom = try #require(calibration.headroom(fromPercent: 10))
        #expect(abs(headroom - 90_000_000) < 1)
    }

    @Test("Falling and flat intervals are not evidence about the exchange rate")
    func onlyRisesCount() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        // Flat throughout: no interval bought anything, so there is no rate to quote.
        let flat = weeklySamples(count: 8, from: 20, step: 0, resetsAt: resetsAt)
        let events = (0..<8).map {
            event("e\($0)", at: Self.now.addingTimeInterval(-Double($0) * 300), output: 100_000)
        }
        #expect(
            ProjectionEngine.calibrate(
                kind: .sevenDay, samples: flat, events: events, now: Self.now) == nil)
    }

    @Test("Too few intervals or too few points produce no rate at all")
    func thinEvidenceIsWithheld() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        // Three intervals, three points — one interval short of the minimum.
        let samples = weeklySamples(count: 4, from: 10, step: 1, resetsAt: resetsAt)
        let events = (1..<4).map {
            event("e\($0)", at: Self.now.addingTimeInterval(-Double(4 - 1 - $0) * 600 - 60),
                output: 200_000)
        }
        #expect(
            ProjectionEngine.calibrate(
                kind: .sevenDay, samples: samples, events: events, now: Self.now) == nil)
    }

    @Test("A window that reset between two polls is not a rise")
    func resetsAreNotRises() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        var samples = weeklySamples(count: 6, from: 10, step: 1, resetsAt: resetsAt)
        // Drop the middle sample back below its predecessor with a fresh reset instant: the
        // window turned over, so the climb across it is not spend, and the weekly rule treats
        // any fall as a boundary.
        samples[3] = Sample(
            t: samples[3].t, fiveHourPct: nil, fiveHourResetsAt: nil, sevenDayPct: 1,
            sevenDayResetsAt: resetsAt.addingTimeInterval(7 * 24 * 3600))
        let events = (1..<6).map {
            event("e\($0)", at: Self.now.addingTimeInterval(-Double(6 - 1 - $0) * 600 - 60),
                output: 200_000)
        }
        // What survives is fewer intervals than the six-sample series would otherwise give.
        let calibration = ProjectionEngine.calibrate(
            kind: .sevenDay, samples: samples, events: events, now: Self.now)
        #expect((calibration?.intervals ?? 0) < 5)
    }

    // MARK: - Per-family separation

    @Test("A family is only measured over intervals it dominated")
    func familyRatesNeedCleanIntervals() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        let samples = weeklySamples(count: 6, from: 10, step: 1, resetsAt: resetsAt)
        // Every interval evenly split between two families: nothing is attributable, so no
        // family rate is reported even though the overall rate is fine.
        var events: [UsageEvent] = []
        for index in 1..<6 {
            let t = Self.now.addingTimeInterval(-Double(6 - 1 - index) * 600 - 60)
            events.append(event("o\(index)", at: t, output: 100_000, model: "claude-opus-5"))
            events.append(event("s\(index)", at: t, output: 100_000, model: "claude-sonnet-5"))
        }

        let calibration = try #require(
            ProjectionEngine.calibrate(
                kind: .sevenDay, samples: samples, events: events, now: Self.now))
        #expect(calibration.families.isEmpty)
        #expect(calibration.familySpread == nil)
    }

    @Test("Two families measured separately give the ratio between them")
    func familySpreadRatio() throws {
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        // Ten intervals: the first five all Opus, the last five all Sonnet. Sonnet buys the
        // same point for four times the tokens, so Opus consumes the limit 4× faster per token.
        let samples = weeklySamples(count: 11, from: 10, step: 1, resetsAt: resetsAt)
        var events: [UsageEvent] = []
        for index in 1..<11 {
            let t = Self.now.addingTimeInterval(-Double(11 - 1 - index) * 600 - 60)
            let opus = index <= 5
            events.append(
                event(
                    "e\(index)", at: t, output: opus ? 200_000 : 800_000,
                    model: opus ? "claude-opus-5" : "claude-sonnet-5"))
        }

        let calibration = try #require(
            ProjectionEngine.calibrate(
                kind: .sevenDay, samples: samples, events: events, now: Self.now))
        #expect(calibration.families.count == 2)
        let spread = try #require(calibration.familySpread)
        #expect(spread.dearest.family == "Opus")
        #expect(spread.cheapest.family == "Sonnet")
        #expect(abs(spread.ratio - 4) < 0.01)
    }

    // MARK: - Pace against the account's own norm

    @Test("Pace compares this cycle against previous ones at the same elapsed fraction")
    func cyclePaceComparesAtEqualFraction() throws {
        let week: TimeInterval = 7 * 24 * 3600
        let resetsAt = Self.now.addingTimeInterval(week / 2)  // half a cycle gone
        let cycleStart = resetsAt.addingTimeInterval(-week)

        var events: [UsageEvent] = []
        // An anchor just before the oldest cycle being compared. A cycle only counts when the
        // record covers it from its start — otherwise its unrecorded early spend would read as
        // a quiet week and drag the norm down — so without this the third cycle is dropped.
        // It sits outside every measured range and contributes to none of the sums.
        events.append(
            event(
                "anchor", at: cycleStart.addingTimeInterval(-3 * week - 1), output: 0))
        // Three prior cycles, each spending 200k output (1Mw) in their first half.
        for step in 1...3 {
            let start = cycleStart.addingTimeInterval(-Double(step) * week)
            events.append(event("p\(step)", at: start.addingTimeInterval(3600), output: 200_000))
            // Spend in each prior cycle's *second* half, which must not be counted: the
            // comparison is at the same fraction, not over the whole cycle.
            events.append(
                event("q\(step)", at: start.addingTimeInterval(week * 0.75), output: 2_000_000))
        }
        // This cycle: twice the typical first-half spend.
        events.append(event("c", at: cycleStart.addingTimeInterval(3600), output: 400_000))

        let pace = try #require(
            Aggregates.cyclePace(
                events: events, kind: .sevenDay, resetsAt: resetsAt, now: Self.now))

        #expect(pace.priorCycles == 3)
        #expect(abs(pace.typical - 1_000_000) < 1)
        #expect(abs(pace.current - 2_000_000) < 1)
        #expect(abs((pace.ratio ?? 0) - 2) < 0.001)
        #expect(abs((pace.deviation ?? 0) - 1) < 0.001)
        #expect(abs(pace.elapsedFraction - 0.5) < 0.001)
    }

    @Test("Cycles predating the transcripts are not counted as quiet ones")
    func cyclesBeforeTheRecordAreNotZeros() throws {
        let week: TimeInterval = 7 * 24 * 3600
        let resetsAt = Self.now.addingTimeInterval(week / 2)
        let cycleStart = resetsAt.addingTimeInterval(-week)
        // Only one prior cycle is covered by the record, which is under the minimum. Counting
        // the seven cycles before the transcripts begin as zeros would manufacture a norm of
        // nothing and report this cycle as infinitely ahead.
        let events = [
            event("old", at: cycleStart.addingTimeInterval(-week + 3600), output: 200_000),
            event("now", at: cycleStart.addingTimeInterval(3600), output: 200_000),
        ]
        #expect(
            Aggregates.cyclePace(
                events: events, kind: .sevenDay, resetsAt: resetsAt, now: Self.now) == nil)
    }

    // MARK: - Profiles

    @Test("The hour profile is zero-filled to 24 buckets and weighted, not counted")
    func hourProfileIsWeightedAndComplete() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 12:00 UTC on the 14th, one day before `now`, so it is inside the trailing window.
        let when = Self.now.addingTimeInterval(-24 * 3600)
        let events = [
            event("a", at: when, output: 100_000),
            // Same hour, cache reads only: a tenth the weight of fresh input, and nothing like
            // the same claim on a limit as the output above.
            UsageEvent(
                key: "b", timestamp: when.addingTimeInterval(60), sessionId: "s", cwd: "/x",
                model: "claude-opus-5", effort: nil, isSidechain: false, agentId: nil,
                tokens: TokenCounts(cacheRead: 100_000)),
        ]

        let profile = Aggregates.hourProfile(
            events: events, days: 30, now: Self.now, calendar: calendar)
        #expect(profile.count == 24)
        #expect(profile.map(\.hour) == Array(0..<24))
        let busy = try #require(profile.first { $0.hour == 12 })
        // 100k output at 5× plus 100k cache reads at 0.1× = 510k weighted.
        #expect(abs(busy.weighted - 510_000) < 1)
        #expect(profile.filter { $0.weighted > 0 }.count == 1)
    }

    @Test("Sub-agent share is weighted spend, not event count")
    func sidechainShareIsWeighted() throws {
        let events = [
            // One main-thread event worth 5×100k = 500k weighted.
            event("main", at: Self.now, output: 100_000),
            // Three sidechain events worth 5×100k/3 each — same total weight, three times the
            // count. A count-based share would read 75%; the weighted answer is half.
            event("s1", at: Self.now, output: 33_333, isSidechain: true),
            event("s2", at: Self.now, output: 33_333, isSidechain: true),
            event("s3", at: Self.now, output: 33_334, isSidechain: true),
        ]
        let share = Aggregates.sidechainShare(from: events)
        #expect(abs(share - 0.5) < 0.001)
    }
}
