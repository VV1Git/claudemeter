import Foundation
import Testing

@testable import UsageCore

/// `ActivityProfile` and `ActivitySignal` are pure functions of the events, the samples and a
/// calendar. Every test here passes an explicit UTC calendar: which local hour an event lands in
/// is the entire subject, so `Calendar.current` would make these assertions a statement about the
/// machine running them rather than about the code.
struct ActivityProfileTests {

    // MARK: - Fixtures

    /// A Thursday, 12:00 UTC.
    private static let now = ISO8601.date(from: "2026-01-15T12:00:00Z")!

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func event(
        _ key: String, at timestamp: Date, output: Int = 100_000, agentId: String? = nil
    ) -> UsageEvent {
        UsageEvent(
            key: key, timestamp: timestamp, sessionId: "session-1", cwd: "/Users/x/proj",
            model: "claude-sonnet-5", effort: nil, isSidechain: agentId != nil, agentId: agentId,
            tokens: TokenCounts(output: output))
    }

    /// `days` complete days of office hours: one message an hour from 09:00 to 17:00 UTC, nothing
    /// overnight. The shape a great many accounts actually have, and the one the flat clock priced
    /// identically to a Sunday at 04:00.
    private func officeHours(days: Int, now: Date = ActivityProfileTests.now) -> [UsageEvent] {
        let calendar = Self.utc
        let today = calendar.startOfDay(for: now)
        var events: [UsageEvent] = []
        for offset in 1...days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            for hour in 9...17 {
                events.append(
                    event("d\(offset)h\(hour)", at: day.addingTimeInterval(Double(hour) * 3600)))
            }
        }
        return events
    }

    private func hours(_ count: Double, after date: Date = ActivityProfileTests.now) -> Date {
        date.addingTimeInterval(count * 3600)
    }

    // MARK: - The flat clock

    @Test("With no transcripts the profile is the flat clock, and mass is just hours")
    func noEventsIsTheFlatClock() {
        let profile = ActivityProfile.build(events: [], now: Self.now, calendar: Self.utc)

        #expect(profile.isFlat)
        #expect(profile == .uniform)
        #expect(profile.intensity(at: Self.now, calendar: Self.utc) == 1)
        // The whole compatibility claim in one line: under this profile every mass the engine
        // computes is a count of wall-clock hours, so the shaped pacing *is* the flat pacing.
        #expect(
            abs(profile.mass(from: Self.now, to: hours(5), calendar: Self.utc) - 5) < 1e-9)
    }

    @Test("A record shorter than the minimum stays flat rather than shaping from two days")
    func aThinRecordStaysFlat() {
        let thin = officeHours(days: 2)
        #expect(ActivityProfile.build(events: thin, now: Self.now, calendar: Self.utc).isFlat)
        #expect(!ActivityProfile.build(events: officeHours(days: 3), now: Self.now, calendar: Self.utc).isFlat)
    }

    // MARK: - Shape

    @Test("Office hours weigh several times a night, and the shape averages to one")
    func nightsWeighLessThanWorkingHours() {
        let profile = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)

        #expect(profile.observedDays == 21)
        let night = profile.hourOfDay[3]
        let midday = profile.hourOfDay[13]
        #expect(midday > 2)
        #expect(night < 0.4)
        #expect(midday / night > 5)
        // Normalized: the shape says *when* the work happens, never how much of it there is.
        let mean = profile.hourOfDay.reduce(0, +) / 24
        #expect(abs(mean - 1) < 1e-9)
        // Days are all alike in this fixture, so the weekday shape has nothing to say.
        #expect(profile.dayOfWeek.allSatisfy { abs($0 - 1) < 1e-9 })
    }

    @Test("An hour that never saw work still carries a floor, not a zero")
    func quietHoursAreFlooredNotZeroed() {
        let profile = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)
        // A zero here would divide the measured pace by a mass of nothing whenever a window
        // opened overnight, and would assert that a 04:00 start can never move.
        #expect(profile.hourOfDay.allSatisfy { $0 >= ActivityProfile.hourFloor })
        #expect(profile.hourOfDay[3] > 0)
    }

    @Test("Three days of evidence shape less than three weeks of the same habit")
    func shrinkagePullsAThinRecordTowardFlat() {
        let thin = ActivityProfile.build(
            events: officeHours(days: 4), now: Self.now, calendar: Self.utc)
        let full = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)

        // Same habit, more of it observed: the shape gets stronger, never weaker.
        #expect(thin.hourOfDay[13] < full.hourOfDay[13])
        #expect(thin.hourOfDay[3] > full.hourOfDay[3])
        #expect(thin.hourOfDay[13] > 1)
    }

    @Test("A weekend account reads as a weekend account")
    func theWeekdayShapeSeparatesWeekendsFromWeekdays() {
        let calendar = Self.utc
        let today = calendar.startOfDay(for: Self.now)
        var events: [UsageEvent] = []
        for offset in 1...28 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            for hour in 9...17 {
                events.append(
                    event(
                        "d\(offset)h\(hour)", at: day.addingTimeInterval(Double(hour) * 3600),
                        output: isWeekend ? 5_000 : 200_000))
            }
        }
        let profile = ActivityProfile.build(events: events, now: Self.now, calendar: calendar)

        // Index 0 is Sunday, 6 Saturday — `Calendar.component(.weekday:)` less one.
        #expect(profile.dayOfWeek[0] < 0.6)
        #expect(profile.dayOfWeek[6] < 0.6)
        #expect(profile.dayOfWeek[3] > 1)
        let mean = profile.dayOfWeek.reduce(0, +) / 7
        #expect(abs(mean - 1) < 1e-9)
    }

    // MARK: - Mass

    @Test("A whole week of activity is a whole week of mean hours")
    func aWeekOfMassIsAWeekOfHours() {
        let profile = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)
        // Both shapes have mean 1 and a week contains each (weekday, hour) pair exactly once, so
        // the shape can move mass *within* a week without inventing or destroying any of it.
        let week = profile.mass(from: Self.now, to: hours(168), calendar: Self.utc)
        #expect(abs(week - 168) < 1e-6)
    }

    @Test("A night holds a fraction of the activity a working day does")
    func aNightHoldsLessThanAWorkingDay() {
        let calendar = Self.utc
        let profile = ActivityProfile.build(events: officeHours(days: 21), now: Self.now, calendar: calendar)
        let midnight = calendar.startOfDay(for: Self.now)

        let night = profile.mass(
            from: midnight, to: midnight.addingTimeInterval(8 * 3600), calendar: calendar)
        let working = profile.mass(
            from: midnight.addingTimeInterval(9 * 3600),
            to: midnight.addingTimeInterval(17 * 3600), calendar: calendar)

        #expect(night < 3)  // eight clock hours worth well under three mean ones
        #expect(working > 15)
        #expect(working / night > 5)
    }

    @Test("Mass is integrated on the calendar's hours, so a spring-forward day is 23 of them")
    func daylightSavingIsCountedOnTheLocalClock() throws {
        // The shape is indexed by *local* hour, so the integrator has to walk local hours. Adding
        // 3600 seconds twenty-four times across a spring-forward day would price 02:00 — an hour
        // that does not exist — and shift every hour after it by one.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let profile = ActivityProfile.uniform
        let start = try #require(ISO8601.date(from: "2026-03-08T08:00:00Z"))  // 00:00 PST
        let end = try #require(ISO8601.date(from: "2026-03-09T07:00:00Z"))  // 00:00 PDT

        #expect(abs(profile.mass(from: start, to: end, calendar: calendar) - 23) < 1e-6)
    }

    @Test("An inverted or absurd span is nothing, not a crash and not a NaN")
    func degenerateSpansAreEmpty() {
        let profile = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)
        #expect(profile.mass(from: Self.now, to: Self.now, calendar: Self.utc) == 0)
        #expect(profile.mass(from: hours(5), to: Self.now, calendar: Self.utc) == 0)
        let far = profile.mass(from: Self.now, to: hours(24 * 400), calendar: Self.utc)
        #expect(far.isFinite)
    }

    // MARK: - The live boost

    @Test("A burst is worth its own persistence, not the whole horizon")
    func theBoostDecaysBackToTheProfile() {
        let profile = ActivityProfile.uniform
        let day = profile.boostedMass(
            from: Self.now, to: hours(24), multiplier: 3, persistence: 3600, calendar: Self.utc)

        // ∫(m − 1)e^(−t/τ) over a horizon far past τ is (m − 1)·τ: two extra mean hours on a
        // 24-hour horizon, not a horizon multiplied by three.
        #expect(abs(day - 26) < 0.01)

        // Inside the first few minutes it is very nearly the full multiplier, which is what makes
        // it useful on the five-hour window.
        let quarter = profile.boostedMass(
            from: Self.now, to: hours(0.25), multiplier: 3, persistence: 3600, calendar: Self.utc)
        #expect(quarter > 0.65)  // against 0.25 unboosted
        #expect(quarter < 0.75)
    }

    @Test("A multiplier of one, or no persistence, is exactly the unboosted mass")
    func aNeutralBoostChangesNothing() {
        let profile = ActivityProfile.build(
            events: officeHours(days: 21), now: Self.now, calendar: Self.utc)
        let plain = profile.mass(from: Self.now, to: hours(30), calendar: Self.utc)
        #expect(
            profile.boostedMass(
                from: Self.now, to: hours(30), multiplier: 1, persistence: 3600,
                calendar: Self.utc) == plain)
        #expect(
            profile.boostedMass(
                from: Self.now, to: hours(30), multiplier: 4, persistence: 0, calendar: Self.utc)
                == plain)
    }

    @Test("A lull removes mass without ever removing more than the horizon holds")
    func aLullCannotRemoveMoreThanThereIs() {
        let profile = ActivityProfile.uniform
        let quiet = profile.boostedMass(
            from: Self.now, to: hours(1), multiplier: ActivitySignal.multiplierFloor,
            persistence: ActivitySignal.persistenceCeiling, calendar: Self.utc)
        #expect(quiet > 0)
        #expect(quiet < 1)
    }

    // MARK: - Reaching a mass

    @Test("Under the flat clock, reaching n mean hours takes n hours")
    func reachingMassUnderAFlatProfile() throws {
        let hit = try #require(
            ActivityProfile.uniform.instant(
                reachingMass: 3, from: Self.now, by: hours(10), multiplier: 1, persistence: 0,
                calendar: Self.utc))
        #expect(abs(hit.timeIntervalSince(hours(3))) < 60)
        // Beyond the limit is nil rather than a date past it — the caller reads nil as "not
        // before this window resets".
        #expect(
            ActivityProfile.uniform.instant(
                reachingMass: 30, from: Self.now, by: hours(10), multiplier: 1, persistence: 0,
                calendar: Self.utc) == nil)
    }

    @Test("A budget that runs out overnight runs out in the morning instead")
    func reachingMassWaitsForTheMorning() throws {
        let calendar = Self.utc
        let profile = ActivityProfile.build(events: officeHours(days: 21), now: Self.now, calendar: calendar)
        let evening = calendar.startOfDay(for: Self.now).addingTimeInterval(21 * 3600)  // 21:00

        // Three mean hours of work left, starting at nine in the evening. On the flat clock that
        // is midnight; on this account's own clock almost nothing happens between 21:00 and 09:00,
        // so it is the following morning — and a warning at midnight would have been one nobody
        // could act on and one that would not have come true.
        let hit = try #require(
            profile.instant(
                reachingMass: 3, from: evening, by: evening.addingTimeInterval(48 * 3600),
                multiplier: 1, persistence: 0, calendar: calendar))
        let hour = calendar.component(.hour, from: hit)
        #expect(hour >= 8)  // 08:00 already carries a quarter of 09:00, through the smoothing
        #expect(hour <= 12)
        #expect(hit.timeIntervalSince(evening) > 10 * 3600)
    }

    // MARK: - The forecast path

    @Test("The forecast's progress is monotone, ends at one, and is linear on a flat clock")
    func progressIsMonotoneAndComplete() throws {
        let shape = ForecastShape(
            elapsedHours: 120, elapsedMass: 120, remainingHours: 24, remainingMass: 24,
            ratePerMass: 0.5, activityMultiplier: 1, persistence: 0, runningAgents: 0,
            profileDays: 0, quietHours: 0, profile: .uniform)
        let steps = shape.progress(from: Self.now, to: hours(24), calendar: Self.utc)

        #expect(steps.count > 1)
        #expect(abs(try #require(steps.last).fraction - 1) < 1e-9)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        // Under the flat clock the activity clock is the wall clock, so the chart draws the
        // straight line it always drew.
        for step in steps {
            let clock = step.t.timeIntervalSince(Self.now) / (24 * 3600)
            #expect(abs(step.fraction - clock) < 1e-9)
        }
    }

    @Test("A forecast plotted overnight is nearly flat until the morning")
    func progressStallsOvernight() throws {
        let calendar = Self.utc
        let profile = ActivityProfile.build(events: officeHours(days: 21), now: Self.now, calendar: calendar)
        let evening = calendar.startOfDay(for: Self.now).addingTimeInterval(20 * 3600)
        let end = evening.addingTimeInterval(24 * 3600)
        let shape = ForecastShape(
            elapsedHours: 120,
            elapsedMass: 120,
            remainingHours: 24,
            remainingMass: profile.mass(from: evening, to: end, calendar: calendar),
            ratePerMass: 0.5, activityMultiplier: 1, persistence: 0, runningAgents: 0,
            profileDays: 21, quietHours: 12, profile: profile)

        let steps = shape.progress(from: evening, to: end, calendar: calendar)
        let atDawn = try #require(steps.first { $0.t >= evening.addingTimeInterval(9 * 3600) })
        let atNoon = try #require(steps.first { $0.t >= evening.addingTimeInterval(16 * 3600) })

        // Thirteen of the twenty-four hours are gone by 09:00 — 54% of the clock — and under a
        // seventh of the work. By noon two thirds of the clock has gone and about four tenths of
        // the work, which is the curve a straight dashed line was drawing as a ramp.
        #expect(atDawn.fraction < 0.15)
        #expect(atNoon.fraction > 0.35)
        #expect(atNoon.fraction < 0.6)
        // Every checkpoint before the working day lags the clock — and once the working day
        // starts the curve overtakes it, which is the same fact seen from the other end: the
        // work is not spread across the horizon, it is concentrated in part of it.
        for step in steps where step.t < evening.addingTimeInterval(13 * 3600) {
            #expect(step.fraction < step.t.timeIntervalSince(evening) / (24 * 3600))
        }
        #expect(abs(try #require(steps.last).fraction - 1) < 1e-9)
    }

    @Test("A week of checkpoints is thinned to something a sparkline can draw")
    func checkpointsAreThinned() throws {
        let full = ActivityProfile.uniform.massCheckpoints(
            from: Self.now, to: hours(168), multiplier: 1, persistence: 0, maximumPoints: 1000,
            calendar: Self.utc)
        let thinned = ActivityProfile.uniform.massCheckpoints(
            from: Self.now, to: hours(168), multiplier: 1, persistence: 0, maximumPoints: 72,
            calendar: Self.utc)

        #expect(full.count == 168)
        #expect(thinned.count <= 73)
        // Thinning drops intermediate points, never the endpoint — the last checkpoint is the one
        // the projected percentage has to land on.
        #expect(thinned.last?.t == full.last?.t)
        #expect(abs(try #require(thinned.last).mass - 168) < 1e-6)
    }

    @Test("The shape carries the wall-clock forecast it replaced")
    func theFlatForecastIsCarriedForComparison() throws {
        // 40% over 60 elapsed hours is 0.667 points an hour, and 40 hours left carries that to
        // 66.7% — the number the row now shows beside its own so the difference can be read
        // rather than trusted. The activity clock is not involved in it at all: it is the same
        // division the engine did before any of this existed.
        let shape = ForecastShape(
            elapsedHours: 60, elapsedMass: 50, remainingHours: 40, remainingMass: 55,
            ratePerMass: 0.8, activityMultiplier: 1, persistence: 0, runningAgents: 0,
            profileDays: 21, quietHours: 12, profile: .uniform)

        // ratePerMass × elapsedMass recovers the reading: 0.8 × 50 = 40%.
        #expect(abs(try #require(shape.flatProjectedAtReset) - 66.667) < 0.01)
        // And the shaped answer it will sit beside: 40% + 0.8 × 55.
        #expect(abs(40 + shape.ratePerMass * shape.remainingMass - 84) < 1e-9)
    }

    @Test("A window with no elapsed time has no wall-clock forecast to compare against")
    func theFlatForecastNeedsAnElapsedWindow() {
        let shape = ForecastShape(
            elapsedHours: 0, elapsedMass: 0, remainingHours: 40, remainingMass: 55,
            ratePerMass: 0.8, activityMultiplier: 1, persistence: 0, runningAgents: 0,
            profileDays: 21, quietHours: 12, profile: .uniform)
        #expect(shape.flatProjectedAtReset == nil)
    }

    // MARK: - The live signal

    @Test("No transcripts and no polls is no signal at all, rather than a confident one")
    func noEvidenceIsNoSignal() {
        #expect(
            ActivitySignal.measure(
                events: [], samples: [], kind: .sevenDay, profile: .uniform, ratePerMass: 0,
                now: Self.now, calendar: Self.utc) == nil)
    }

    @Test("A burst in progress reads above the account's own normal, and is capped")
    func aBurstReadsAboveNormal() throws {
        var events = officeHours(days: 21)
        // Twenty times an ordinary message, inside the live window.
        events.append(event("burst", at: Self.now.addingTimeInterval(-300), output: 2_000_000))
        let profile = ActivityProfile.build(events: events, now: Self.now, calendar: Self.utc)

        let signal = try #require(
            ActivitySignal.measure(
                events: events, samples: [], kind: .sevenDay, profile: profile, ratePerMass: 0,
                now: Self.now, calendar: Self.utc))

        #expect(signal.multiplier == ActivitySignal.multiplierCeiling)
        #expect(signal.isActive)
        #expect(!signal.sawLimitSeries)
    }

    @Test("Quiet during working hours reads as a lull; quiet at four in the morning does not")
    func theLullIsReadAgainstTheHourItHappensIn() throws {
        let calendar = Self.utc
        let profile = ActivityProfile.build(events: officeHours(days: 21), now: Self.now, calendar: calendar)
        let midday = calendar.startOfDay(for: Self.now).addingTimeInterval(14 * 3600)
        let smallHours = calendar.startOfDay(for: Self.now).addingTimeInterval(4 * 3600)

        let atWork = try #require(
            ActivitySignal.measure(
                events: officeHours(days: 21), samples: [], kind: .sevenDay, profile: profile,
                ratePerMass: 0, now: midday, calendar: calendar))
        let atNight = try #require(
            ActivitySignal.measure(
                events: officeHours(days: 21), samples: [], kind: .sevenDay, profile: profile,
                ratePerMass: 0, now: smallHours, calendar: calendar))

        // Nothing happening in an hour that usually carries three times an average hour is real
        // evidence about the next one.
        #expect(atWork.multiplier < 0.5)
        // Nothing happening at 04:00 is close to what 04:00 always is. The prior sits at
        // *average* intensity precisely so this case lands near 1 instead of reading as the same
        // slowdown: an idle hour where the profile expects a quarter of an average hour is a
        // fifth below normal, where an idle hour where it expects two and a half is two thirds
        // below. What the forecast acts on is that contrast, not either number alone.
        #expect(atNight.multiplier > 0.75)
        #expect(atNight.multiplier > 2 * atWork.multiplier)
        #expect(!atWork.isActive)
    }

    @Test("Sub-agents running right now are counted, and hold the burst open longer")
    func runningSubAgentsExtendThePersistence() throws {
        var events = officeHours(days: 21)
        // A fan-out that started a minute ago: three agents, no stretch behind them.
        for index in 1...3 {
            events.append(
                event(
                    "agent-\(index)", at: Self.now.addingTimeInterval(-60), output: 400_000,
                    agentId: "agent-\(index)"))
        }
        let profile = ActivityProfile.build(events: events, now: Self.now, calendar: Self.utc)
        let signal = try #require(
            ActivitySignal.measure(
                events: events, samples: [], kind: .sevenDay, profile: profile, ratePerMass: 0,
                now: Self.now, calendar: Self.utc))

        #expect(signal.runningAgents == 3)
        #expect(signal.multiplier > 1)
        // A minute-old stretch would otherwise be believed for the floor. Work already handed to
        // a sub-agent will keep spending after the last message this app has seen.
        #expect(signal.persistence >= ActivitySignal.agentPersistenceFloor)
    }

    @Test("A stretch that has run for hours is believed longer than one that just started")
    func persistenceFollowsHowLongTheStretchHasRun() throws {
        func signal(stretchHours: Double) throws -> ActivitySignal {
            var events = officeHours(days: 21)
            var offset = 0.0
            while offset <= stretchHours * 60 {
                events.append(
                    event("live-\(offset)", at: Self.now.addingTimeInterval(-offset * 60)))
                offset += 5
            }
            let profile = ActivityProfile.build(events: events, now: Self.now, calendar: Self.utc)
            return try #require(
                ActivitySignal.measure(
                    events: events, samples: [], kind: .sevenDay, profile: profile,
                    ratePerMass: 0, now: Self.now, calendar: Self.utc))
        }

        let fresh = try signal(stretchHours: 0.2)
        let long = try signal(stretchHours: 3)
        #expect(fresh.persistence == ActivitySignal.persistenceFloor)
        #expect(long.persistence > fresh.persistence)
        #expect(long.persistence <= ActivitySignal.persistenceCeiling)
        #expect(fresh.isActive && long.isActive)
    }

    @Test("The limit series speaks for the machines the transcripts cannot see")
    func theLimitSeriesCanRaiseTheSignalAlone() throws {
        // No transcripts at all — the work is happening on another machine, or in the desktop
        // app. The only evidence is the window itself climbing faster than its own pace expects.
        let samples = (0..<7).map { index -> Sample in
            Sample(
                t: Self.now.addingTimeInterval(-Double(6 - index) * 15 * 60),
                fiveHourPct: nil, fiveHourResetsAt: nil,
                sevenDayPct: 40 + Double(index) * 2, sevenDayResetsAt: hours(48))
        }
        let signal = try #require(
            ActivitySignal.measure(
                events: [], samples: samples, kind: .sevenDay, profile: .uniform,
                ratePerMass: 0.5, now: Self.now, calendar: Self.utc))

        #expect(signal.sawLimitSeries)
        #expect(signal.multiplier > 1.5)
        #expect(!signal.isActive)  // nothing local is running, and it says so
        #expect(signal.runningAgents == 0)
    }

    @Test("A window that has barely moved weighs less than the quantum it was measured with")
    func aCoarseLimitReadingCarriesLessWeight() throws {
        // Two polls twenty minutes apart on a window pacing a fifth of a point an hour: the whole
        // signal is smaller than the rounding step it was reported with, so it must not be
        // allowed to swing the forecast.
        let samples = [
            Sample(
                t: Self.now.addingTimeInterval(-25 * 60), fiveHourPct: nil, fiveHourResetsAt: nil,
                sevenDayPct: 40, sevenDayResetsAt: hours(48)),
            Sample(
                t: Self.now, fiveHourPct: nil, fiveHourResetsAt: nil, sevenDayPct: 41,
                sevenDayResetsAt: hours(48)),
        ]
        let signal = try #require(
            ActivitySignal.measure(
                events: [], samples: samples, kind: .sevenDay, profile: .uniform,
                ratePerMass: 0.2, now: Self.now, calendar: Self.utc))

        #expect(signal.evidence < 0.1)
        // A point in twenty-five minutes is twelve times the expected pace, and it moves the
        // multiplier by well under a factor of two.
        #expect(signal.multiplier < 2)
    }
}
