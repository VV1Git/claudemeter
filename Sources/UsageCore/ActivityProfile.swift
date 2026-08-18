import Foundation

// MARK: - Activity profile

/// When this account actually works, as two multiplicative shapes: one over the local hour of
/// day, one over the local day of week.
///
/// The weekly forecast used to divide the week's consumption by the hours the week had been open
/// and multiply by the hours it had left, which prices 04:00 on a Sunday exactly like 15:00 on a
/// Tuesday. Nobody spends a rate limit in their sleep, so on any account with a sleep cycle that
/// is wrong by a large factor over any horizon shorter than a whole week — and wrong in a
/// direction that changes through the week. A Friday-evening reading is carried across two nights
/// that will be spent asleep; a Monday-morning one is carried across five working days. The flat
/// clock cannot tell those apart, and the difference between them is most of the forecast.
///
/// Both shapes are *ratios*, and that is what makes them usable at all here. The weekly limit
/// counts work this app cannot see — other machines, the desktop app, claude.ai — so any absolute
/// level read off local transcripts is wrong by whatever share of the account's work happens
/// elsewhere. A shape normalized to mean 1 is unchanged by that share as long as it is roughly
/// constant across the day, which is the same defence `dailyVariation` already stands on.
///
/// Measured on this account's own corpus — 30,893 events over 26 complete days — the shape is not
/// a small correction. The hour multipliers run from 0.2 at 06:00 to 2.0 at 21:00, a ten-to-one
/// spread, and the weekday ones from 0.73 on a Friday to 1.45 on a Wednesday. On a live weekly
/// reading of 24% with 62 hours gone and 105 left, the flat clock projected 64.8% and the activity
/// clock 70.4%: the window had opened across this account's quiet stretch, so the pace it had been
/// keeping was higher than the clock implied, and what remained of the week still held the heavy
/// Wednesday.
///
/// Deliberately conservative in three ways, because a shape estimated from four weeks of one
/// machine is evidence, not gospel:
///
/// * it is **shrunk toward flat** by how many days were observed, so a new install forecasts
///   exactly as the flat clock did and the shape arrives gradually as the days accumulate;
/// * every hour is **floored** well above zero, because an hour that saw no work in four weeks is
///   not an hour in which work is impossible;
/// * the leverage it is allowed over the *measured* pace is bounded — see
///   `ProjectionEngine.massLeverage`.
public struct ActivityProfile: Sendable, Equatable {
    /// 24 multipliers over the local hour of day, mean 1.
    public let hourOfDay: [Double]
    /// 7 multipliers over the local weekday, mean 1, index 0 = Sunday to match
    /// `Calendar.component(.weekday:)` less one.
    public let dayOfWeek: [Double]
    /// Complete local days the shapes were measured over. Zero means no shape at all.
    public let observedDays: Int
    /// Mean weighted tokens per hour across those days.
    ///
    /// A *level*, and the one number here that does not survive the unseen-work caveat — so it is
    /// never used to set a forecast's level. It exists so `ActivitySignal` can ask whether the
    /// last half hour was busy *for this account*, which is a ratio again.
    public let meanWeightedPerHour: Double

    /// The flat clock: what every caller falls back to, and what the forecast used to be.
    public static let uniform = ActivityProfile(
        hourOfDay: Array(repeating: 1, count: 24),
        dayOfWeek: Array(repeating: 1, count: 7),
        observedDays: 0,
        meanWeightedPerHour: 0)

    public init(
        hourOfDay: [Double], dayOfWeek: [Double], observedDays: Int, meanWeightedPerHour: Double
    ) {
        // A wrong-sized or non-finite shape becomes flat rather than reaching the integrator,
        // where a NaN multiplier would propagate into the projection and out to Swift Charts.
        let hours = hourOfDay.count == 24 && hourOfDay.allSatisfy { $0.isFinite && $0 >= 0 }
        let days = dayOfWeek.count == 7 && dayOfWeek.allSatisfy { $0.isFinite && $0 >= 0 }
        self.hourOfDay = hours ? hourOfDay : Array(repeating: 1, count: 24)
        self.dayOfWeek = days ? dayOfWeek : Array(repeating: 1, count: 7)
        self.observedDays = hours && days ? max(0, observedDays) : 0
        self.meanWeightedPerHour =
            meanWeightedPerHour.isFinite && meanWeightedPerHour > 0 ? meanWeightedPerHour : 0
    }

    /// True when this is the flat clock — no shape was measurable, so nothing below can move a
    /// forecast away from the wall-clock pacing it has always done.
    public var isFlat: Bool { observedDays == 0 }

    // MARK: Construction

    /// Complete local days behind the shapes.
    ///
    /// Four whole weeks rather than the 30 days the hour-of-day *chart* draws, and the difference
    /// matters here in a way it does not there: 30 days gives two weekdays five appearances and
    /// the other five four, so a day-of-week shape read off it carries a 25% bias that depends on
    /// nothing but which weekday the window happened to start on. Four weeks gives every weekday
    /// the same count.
    public static let profileDays = 28
    /// Fewer complete days than this and there is no shape worth applying.
    public static let minimumDays = 3

    /// Days of evidence at which the hour-of-day shape is applied at half strength.
    ///
    /// A week: one pass through every weekday, and the point at which "this account is quiet at
    /// 04:00" stops being a statement about last Tuesday.
    public static let hourPriorDays: Double = 7
    /// Weeks of evidence at which the day-of-week shape is applied at half strength. Two, because
    /// a single week cannot distinguish "quiet on Sundays" from "was away last Sunday".
    public static let weekPriorWeeks: Double = 2

    /// Floors and ceilings on the two shapes, applied after shrinkage.
    ///
    /// The floor is the one that earns its keep. Four weeks of transcripts routinely contain
    /// hours with no work at all, and a zero there would assert that a window opened at 04:00 can
    /// never move — which would divide the measured pace by a mass of nothing. A twentieth of
    /// average is a night that contributes about 25 minutes of expected work across eight hours,
    /// which is roughly what a night with an occasional late finish looks like.
    public static let hourFloor: Double = 0.05
    public static let hourCeiling: Double = 6
    public static let dayFloor: Double = 0.25
    public static let dayCeiling: Double = 3

    /// Intensity below which an hour counts as quiet for the purpose of *describing* a horizon.
    /// Reporting only, so nothing is computed from it.
    public static let quietThreshold: Double = 0.35

    /// Builds both shapes from the transcript corpus. Returns `.uniform` — never nil — so every
    /// caller has a profile to integrate and the no-evidence path is the flat clock by
    /// construction rather than by a branch each caller has to remember.
    ///
    /// Today is excluded because it is a partial day, and days before the transcripts begin are
    /// excluded because absence of evidence is not an idle day. Both rules are `dailyVariation`'s
    /// already; they are restated here rather than shared because that function needs a
    /// zero-filled *series* and this one needs per-hour totals.
    public static func build(
        events: [UsageEvent], now: Date, calendar: Calendar = .current
    ) -> ActivityProfile {
        guard let index = LocalDayIndex(days: profileDays, endingAt: now, calendar: calendar)
        else { return .uniform }

        var hourTotals = [Double](repeating: 0, count: 24)
        var dayTotals = [Double](repeating: 0, count: index.dayCount)
        var total = 0.0
        var firstDay: Int?

        for event in events where event.model != Pricing.syntheticModel {
            guard let day = index.day(of: event.timestamp) else { continue }
            let weight = LimitWeight.of(event.tokens)
            guard weight > 0, weight.isFinite else { continue }
            hourTotals[index.hour(of: event.timestamp, day: day)] += weight
            dayTotals[day] += weight
            total += weight
            if firstDay == nil || day < firstDay! { firstDay = day }
        }
        guard total > 0, let firstDay else { return .uniform }

        // Zero-filled from the first day with any work: an idle Sunday inside the record is a
        // real fact about this account, and dropping it would report the shape of busy days only.
        let observed = (firstDay..<index.dayCount).map {
            (weekday: index.weekday(of: $0), total: dayTotals[$0])
        }
        guard observed.count >= minimumDays else { return .uniform }

        let dayCount = Double(observed.count)
        let dayMean = total / dayCount
        guard dayMean > 0 else { return .uniform }

        // Day of week: each weekday's own mean against the mean day. Weekdays the record does not
        // reach stay neutral rather than reading as empty ones.
        var weekdaySum = [Double](repeating: 0, count: 7)
        var weekdayCount = [Double](repeating: 0, count: 7)
        for day in observed {
            weekdaySum[day.weekday] += day.total
            weekdayCount[day.weekday] += 1
        }
        let rawDayOfWeek = (0..<7).map { index -> Double in
            guard weekdayCount[index] > 0 else { return 1 }
            return weekdaySum[index] / weekdayCount[index] / dayMean
        }

        // Hour of day: pooled across every observed day, then smoothed. Bucket boundaries are an
        // artefact of the clock, not of behaviour — work at 23:58 and work at 00:02 are the same
        // habit — and a three-tap circular kernel keeps a session that habitually ends near an
        // hour mark from carving a cliff into the shape.
        let hourMean = total / 24
        let rawHourOfDay = smoothed(hourTotals.map { $0 / hourMean })

        let hourStrength = dayCount / (dayCount + hourPriorDays)
        let weeks = dayCount / 7
        let dayStrength = weeks / (weeks + weekPriorWeeks)

        return ActivityProfile(
            hourOfDay: normalized(
                rawHourOfDay.map {
                    min(max(1 + hourStrength * ($0 - 1), hourFloor), hourCeiling)
                }),
            dayOfWeek: normalized(
                rawDayOfWeek.map {
                    min(max(1 + dayStrength * ($0 - 1), dayFloor), dayCeiling)
                }),
            observedDays: observed.count,
            meanWeightedPerHour: total / (dayCount * 24))
    }

    /// Circular `[0.25, 0.5, 0.25]`.
    private static func smoothed(_ values: [Double]) -> [Double] {
        let count = values.count
        guard count > 2 else { return values }
        return (0..<count).map { index in
            let before = values[(index + count - 1) % count]
            let after = values[(index + 1) % count]
            return 0.25 * before + 0.5 * values[index] + 0.25 * after
        }
    }

    /// Rescales to mean 1. The forecast's arithmetic is invariant to this — a constant factor
    /// cancels between the elapsed mass and the remaining one — but every figure derived from a
    /// mass is quoted in "mean hours", and that unit only means anything if the mean is 1.
    private static func normalized(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0, mean.isFinite else { return values }
        return values.map { $0 / mean }
    }

    // MARK: Intensity and mass

    /// Expected activity at `date` as a multiple of this account's average hour.
    public func intensity(at date: Date, calendar: Calendar = .current) -> Double {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date) - 1
        guard hour >= 0, hour < 24, weekday >= 0, weekday < 7 else { return 1 }
        return hourOfDay[hour] * dayOfWeek[weekday]
    }

    /// Expected activity between two instants, in *mean hours* — the hours an average stretch of
    /// this account's time would have had to run to contain as much work.
    ///
    /// This is the clock the forecast is paced against. Under `.uniform` it is exactly the number
    /// of wall-clock hours, which is what makes the flat pacing this replaces a special case of
    /// it rather than a different rule.
    public func mass(from: Date, to: Date, calendar: Calendar = .current) -> Double {
        boostedMass(from: from, to: to, multiplier: 1, persistence: 0, calendar: calendar)
    }

    /// `mass`, with the near end scaled by a live-activity multiplier that decays back to the
    /// profile with time constant `persistence`.
    ///
    /// A burst in progress says a great deal about the next hour and almost nothing about the day
    /// after tomorrow, and the exponential is the shape of that statement. Multiplying the whole
    /// horizon by it instead is the mistake this engine already documents at length: a 45-minute
    /// slope carried across 168 hours printed 171% on a week that finished at 23%. Decayed over a
    /// couple of hours, the same burst is worth about a point.
    public func boostedMass(
        from: Date, to: Date, multiplier: Double, persistence: TimeInterval,
        calendar: Calendar = .current
    ) -> Double {
        var total = 0.0
        walk(from: from, to: to, calendar: calendar) { start, end, intensity in
            total += intensity * Self.boostIntegral(
                from: start, to: end, multiplier: multiplier, persistence: persistence)
            return true
        }
        return total
    }

    /// Wall-clock hours in `[from, to]` the profile expects to be quiet. Reporting only: this is
    /// what lets a row say "two nights before it resets" rather than making the reader infer it.
    public func quietHours(from: Date, to: Date, calendar: Calendar = .current) -> Double {
        var total = 0.0
        walk(from: from, to: to, calendar: calendar) { start, end, intensity in
            if intensity < Self.quietThreshold { total += end - start }
            return true
        }
        return total
    }

    /// Cumulative boosted mass at each hour boundary in `[from, to]`, ending on `to` itself.
    ///
    /// This is what lets a chart draw the forecast as the curve it actually is. A dashed straight
    /// line from here to the reset says the window climbs all night, which is the very claim this
    /// file exists to stop the engine from making — the number at the end of the line would be
    /// shaped and every point along it flat.
    ///
    /// Thinned to `maximumPoints` by taking every nth boundary, always keeping the last: a week
    /// is 168 boundaries and a sparkline 300 points wide cannot show them.
    public func massCheckpoints(
        from: Date, to: Date, multiplier: Double, persistence: TimeInterval,
        maximumPoints: Int = 96, calendar: Calendar = .current
    ) -> [(t: Date, mass: Double)] {
        var checkpoints: [(t: Date, mass: Double)] = []
        var total = 0.0
        walk(from: from, to: to, calendar: calendar) { start, end, intensity in
            total += intensity * Self.boostIntegral(
                from: start, to: end, multiplier: multiplier, persistence: persistence)
            checkpoints.append((from.addingTimeInterval(end * 3600), total))
            return true
        }
        guard maximumPoints > 1, checkpoints.count > maximumPoints else { return checkpoints }
        let stride = Int((Double(checkpoints.count) / Double(maximumPoints)).rounded(.up))
        var thinned = checkpoints.enumerated()
            .filter { $0.offset % stride == 0 }
            .map(\.element)
        if let last = checkpoints.last, thinned.last?.t != last.t { thinned.append(last) }
        return thinned
    }

    /// The instant by which `target` mean hours of activity have accrued, or nil if that is
    /// further out than `limit`.
    ///
    /// Within a segment the crossing is interpolated linearly. The segments are at most an hour
    /// long and the accrual is monotone across one, so that places the instant to within a few
    /// minutes — finer than the row prints it, and far finer than the forecast's own interval.
    public func instant(
        reachingMass target: Double, from: Date, by limit: Date, multiplier: Double,
        persistence: TimeInterval, calendar: Calendar = .current
    ) -> Date? {
        guard target.isFinite, target > 0, from < limit else { return nil }
        var accrued = 0.0
        var crossing: Date?
        walk(from: from, to: limit, calendar: calendar) { start, end, intensity in
            let segment = intensity * Self.boostIntegral(
                from: start, to: end, multiplier: multiplier, persistence: persistence)
            guard segment > 0 else { return true }
            if accrued + segment >= target {
                let share = (target - accrued) / segment
                crossing = from.addingTimeInterval((start + share * (end - start)) * 3600)
                return false
            }
            accrued += segment
            return true
        }
        return crossing
    }

    /// ∫ 1 + (m − 1)·e^(−t/τ) dt over `[from, to]`, both in hours from the horizon's start.
    private static func boostIntegral(
        from: Double, to: Double, multiplier: Double, persistence: TimeInterval
    ) -> Double {
        let span = to - from
        guard span > 0 else { return 0 }
        let tau = persistence / 3600
        guard tau > 0, multiplier.isFinite, multiplier != 1 else { return span }
        let decayed = tau * ((-from / tau).exponential() - (-to / tau).exponential())
        let total = span + (multiplier - 1) * decayed
        // A multiplier under 1 removes mass, and only ever less than the segment holds — but the
        // arithmetic is floating point over an exponential, so the floor is stated rather than
        // reasoned about.
        return max(0, total.isFinite ? total : span)
    }

    /// Most segments one walk will take: fifteen days at an hour each, comfortably past the
    /// longest window this app projects. Whatever is left after that accrues at mean intensity,
    /// so an absurd horizon degrades to the flat clock instead of being silently truncated.
    private static let maximumSegments = 24 * 15

    /// Splits `[from, to]` at local hour boundaries, handing each piece to `body` as its start and
    /// end offsets in hours from `from` and the intensity across it. `body` returns false to stop.
    ///
    /// Split on the *calendar's* hour boundaries rather than by adding 3600 seconds, so the hour
    /// a piece is priced at is the local hour a human would name — including across a daylight
    /// saving change, where one local hour is 3600 seconds of nothing or happens twice.
    private func walk(
        from: Date, to: Date, calendar: Calendar, _ body: (Double, Double, Double) -> Bool
    ) {
        guard from < to, from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite
        else { return }
        var cursor = from
        var offset = 0.0
        var steps = 0
        while cursor < to {
            guard steps < Self.maximumSegments else {
                let remainder = to.timeIntervalSince(cursor) / 3600
                _ = body(offset, offset + remainder, 1)
                return
            }
            steps += 1
            let boundary =
                calendar.dateInterval(of: .hour, for: cursor)?.end
                ?? cursor.addingTimeInterval(3600)
            // A boundary that does not advance would spin forever; step a whole hour instead.
            let end = min(boundary > cursor ? boundary : cursor.addingTimeInterval(3600), to)
            let length = end.timeIntervalSince(cursor) / 3600
            guard length > 0 else { return }
            if !body(offset, offset + length, intensity(at: cursor, calendar: calendar)) { return }
            offset += length
            cursor = end
        }
    }
}

extension Double {
    /// `Foundation.exp` under a name that reads at the call site, and guarded: the argument here
    /// is always ≤ 0, but an underflow to zero is the right answer and an overflow is not one.
    fileprivate func exponential() -> Double {
        guard isFinite else { return self < 0 ? 0 : .infinity }
        return Foundation.exp(self)
    }
}

// MARK: - Live activity

/// What is happening *right now*, as a multiplier on the profile and a time constant for how long
/// it is worth believing.
///
/// The profile knows what a Tuesday afternoon usually looks like. It does not know that this
/// particular Tuesday afternoon is running four sub-agents through a large refactor, or that the
/// machine has been idle since lunch. Both are worth points on a five-hour horizon and about a
/// point on a weekly one, and both are visible without asking anything of the user.
///
/// Two independent sources, pooled by how much each is worth:
///
/// 1. **The limit series.** Points gained on this window over the last 90 minutes, against what
///    the window's own measured pace expects over the same stretch. Account-wide by construction
///    — it is the same number the forecast is anchored on — so it sees the other machine and the
///    desktop app. Coarse: the API reports whole points, so its weight is scaled by how far the
///    expected movement stands above that quantum.
/// 2. **The transcripts.** Weighted tokens in the last 30 minutes against this account's average
///    half hour. Fine-grained and immediate, but blind to every surface except this one.
///
/// Both reduce to a dimensionless "observed against average", so they pool without either needing
/// to be converted into the other's units — and neither carries a level, which is what keeps the
/// unseen-work caveat from mattering.
public struct ActivitySignal: Sendable, Equatable {
    /// Multiplier on the profile for the near horizon. 1 is "exactly as usual".
    public let multiplier: Double
    /// Time constant for the decay back to the profile.
    public let persistence: TimeInterval
    /// Distinct sub-agents seen within the idle gap — the fan-out that is running right now.
    public let runningAgents: Int
    /// Whether this machine has produced a message within the idle gap.
    public let isActive: Bool
    /// Pooled weight behind `multiplier`, 0...2. Zero is no signal at all, and the engine treats
    /// that as no signal rather than as a multiplier of 1 measured badly.
    public let evidence: Double
    /// Whether the limit series contributed — i.e. whether the signal can see other machines.
    public let sawLimitSeries: Bool

    public init(
        multiplier: Double, persistence: TimeInterval, runningAgents: Int, isActive: Bool,
        evidence: Double, sawLimitSeries: Bool
    ) {
        self.multiplier = multiplier
        self.persistence = persistence
        self.runningAgents = runningAgents
        self.isActive = isActive
        self.evidence = evidence
        self.sawLimitSeries = sawLimitSeries
    }

    /// Trailing transcript span behind the token side of the signal. Three default idle gaps:
    /// long enough to average over one slow tool call, short enough to notice a session that
    /// ended twenty minutes ago.
    public static let transcriptWindow: TimeInterval = 30 * 60
    /// Trailing poll span behind the limit side. Longer than the transcript window because the
    /// signal there is quantized to whole points, and a window has to move for a while before it
    /// moves by more than a rounding step.
    public static let limitWindow: TimeInterval = 90 * 60
    /// Shortest poll span worth differencing.
    public static let minimumLimitSpan: TimeInterval = 20 * 60

    /// Pseudo-evidence pulling the multiplier toward 1, in units of one source's full weight.
    ///
    /// This is what makes a quiet 04:00 read as ordinary rather than as a slowdown. The prior sits
    /// at *average* intensity rather than at the profile's expectation for the moment, so an hour
    /// where the profile expects nothing and nothing happened lands at a multiplier of 1, while
    /// the same nothing during a normally busy afternoon lands well below it. An hour where the
    /// profile expects nothing and a great deal is happening still reads as news, which is the
    /// asymmetry that matters: an idle night is what nights are, a working night is not.
    public static let priorEvidence: Double = 1

    /// Bounds on the multiplier. Four is about the most a genuine fan-out sustains against an
    /// account's own average; a fifth is a machine that has stopped without having stopped.
    public static let multiplierCeiling: Double = 4
    public static let multiplierFloor: Double = 0.2

    /// Bounds on the persistence, and the value used when this machine has no transcripts to date
    /// the burst from.
    public static let persistenceFloor: TimeInterval = 20 * 60
    public static let persistenceCeiling: TimeInterval = 2 * 3600
    public static let neutralPersistence: TimeInterval = 45 * 60
    /// A fan-out that has started will keep spending after the last message this app has seen, so
    /// a burst with sub-agents in it is believed for at least this long regardless of how young
    /// the stretch is.
    public static let agentPersistenceFloor: TimeInterval = 30 * 60
    /// How far back the stretch walk looks. Past this the answer is "idle a long time", and the
    /// persistence is at its ceiling either way.
    private static let stretchLookback: TimeInterval = 6 * 3600

    /// Measures the signal. `ratePerMass` is the window's own measured pace in points per mean
    /// hour — the expectation the limit series is compared against — and passing a non-positive
    /// one simply drops that source.
    ///
    /// Returns nil when neither source has anything to say, so the caller can tell "no signal"
    /// from "measured, and it says nothing is unusual".
    public static func measure(
        events: [UsageEvent], samples: [Sample], kind: WindowKind, profile: ActivityProfile,
        ratePerMass: Double, now: Date, idleGap: TimeInterval = Aggregates.defaultActiveGap,
        calendar: Calendar = .current
    ) -> ActivitySignal? {
        var weight = 0.0
        var observed = 0.0
        var expected = 0.0

        // MARK: the transcripts
        let liveStart = now.addingTimeInterval(-transcriptWindow)
        let agentCutoff = now.addingTimeInterval(-idleGap)
        let stretchStart = now.addingTimeInterval(-stretchLookback)
        var liveWeight = 0.0
        var agents = Set<String>()
        var lastEvent: Date?
        var recent: [Date] = []

        for event in events where event.model != Pricing.syntheticModel {
            let timestamp = event.timestamp
            guard timestamp <= now else { continue }
            if lastEvent == nil || timestamp > lastEvent! { lastEvent = timestamp }
            if timestamp >= stretchStart { recent.append(timestamp) }
            if timestamp > liveStart { liveWeight += LimitWeight.of(event.tokens) }
            if timestamp >= agentCutoff, let agent = event.agentId { agents.insert(agent) }
        }

        if profile.meanWeightedPerHour > 0 {
            let hours = transcriptWindow / 3600
            let ratio = liveWeight / (profile.meanWeightedPerHour * hours)
            let usual = profile.mass(from: liveStart, to: now, calendar: calendar) / hours
            if ratio.isFinite, usual.isFinite {
                weight += 1
                observed += ratio
                expected += usual
            }
        }

        // MARK: the limit series
        var sawLimitSeries = false
        if ratePerMass > 0, ratePerMass.isFinite {
            let series = ProjectionEngine.usableSamples(
                samples, kind: kind, now: now, window: limitWindow)
            if let first = series.first, let last = series.last, series.count >= 2,
                let before = first.percent(for: kind), let after = last.percent(for: kind)
            {
                let span = last.t.timeIntervalSince(first.t)
                let hours = span / 3600
                // A fall is usage ageing out of the rolling window, not a refund, and it is not
                // evidence that the next hour will be quiet — so the floor is zero, not the drop.
                let gained = max(0, after - before)
                let averagePoints = ratePerMass * hours
                if span >= minimumLimitSpan, averagePoints > 0 {
                    let ratio = gained / averagePoints
                    let usual =
                        profile.mass(from: first.t, to: last.t, calendar: calendar) / hours
                    // Weighted by how far the movement this span *should* contain stands above
                    // the reporting quantum. A window that gains half a point in ninety minutes
                    // is being measured with a ruler marked in whole points, and it says so.
                    let quality = averagePoints
                        / (averagePoints + ProjectionEngine.reportingQuantum)
                    if ratio.isFinite, usual.isFinite, quality.isFinite {
                        weight += quality
                        observed += quality * ratio
                        expected += quality * usual
                        sawLimitSeries = true
                    }
                }
            }
        }

        guard weight > 0 else { return nil }

        let raw = (observed + priorEvidence) / (expected + priorEvidence)
        let multiplier = raw.isFinite ? min(max(raw, multiplierFloor), multiplierCeiling) : 1

        // MARK: how long to believe it
        //
        // Lindy, and measurably so on a corpus of session lengths: a stretch that has already run
        // two hours is far likelier to run another hour than one that started five minutes ago,
        // and the same holds of a machine that has been quiet since lunch. Half the elapsed state
        // is the median remaining life of a stretch whose lengths are heavy-tailed, which is what
        // both sides of this account's own distribution look like.
        var persistence = neutralPersistence
        var isActive = false
        if let lastEvent {
            let sinceLast = now.timeIntervalSince(lastEvent)
            if sinceLast <= idleGap {
                isActive = true
                let ordered = recent.sorted()
                var index = ordered.count - 1
                var began = lastEvent
                while index > 0, ordered[index].timeIntervalSince(ordered[index - 1]) <= idleGap {
                    index -= 1
                    began = ordered[index]
                }
                persistence = now.timeIntervalSince(began) / 2
            } else {
                persistence = sinceLast / 2
            }
        }
        persistence = min(max(persistence, persistenceFloor), persistenceCeiling)
        if !agents.isEmpty { persistence = max(persistence, agentPersistenceFloor) }

        return ActivitySignal(
            multiplier: multiplier,
            persistence: persistence,
            runningAgents: agents.count,
            isActive: isActive,
            evidence: weight,
            sawLimitSeries: sawLimitSeries)
    }
}

// MARK: - What the shape did

/// The inputs behind a shaped projection, carried out with it so a row can say *why* it differs
/// from the flat pace rather than leaving the reader to guess.
///
/// Every field is a measurement rather than a decision, which is what makes it safe to render:
/// there is nothing here the projection did not already act on.
public struct ForecastShape: Sendable, Equatable {
    /// Wall-clock hours the window has been open, and the mean hours of activity the profile puts
    /// in them. Equal under the flat clock.
    public let elapsedHours: Double
    public let elapsedMass: Double
    /// Wall-clock hours to the reset, and the mean hours of activity expected across them —
    /// including the live signal's decaying contribution.
    public let remainingHours: Double
    public let remainingMass: Double
    /// The pace the forecast was carried forward at, in points per mean hour.
    public let ratePerMass: Double
    /// The live multiplier and how long it was believed for.
    public let activityMultiplier: Double
    public let persistence: TimeInterval
    public let runningAgents: Int
    /// Complete days behind the profile. Zero means the flat clock — no shape was applied.
    public let profileDays: Int
    /// Wall-clock hours before the reset the profile expects to be quiet.
    public let quietHours: Double
    /// The shape itself, so a chart can redraw the path the forecast took rather than a straight
    /// line to its endpoint. Carried rather than rebuilt: a view that re-derives the profile from
    /// the events is a view that can draw a different forecast from the one printed beside it.
    public let profile: ActivityProfile

    public init(
        elapsedHours: Double, elapsedMass: Double, remainingHours: Double, remainingMass: Double,
        ratePerMass: Double, activityMultiplier: Double, persistence: TimeInterval,
        runningAgents: Int, profileDays: Int, quietHours: Double,
        profile: ActivityProfile = .uniform
    ) {
        self.profile = profile
        self.elapsedHours = elapsedHours
        self.elapsedMass = elapsedMass
        self.remainingHours = remainingHours
        self.remainingMass = remainingMass
        self.ratePerMass = ratePerMass
        self.activityMultiplier = activityMultiplier
        self.persistence = persistence
        self.runningAgents = runningAgents
        self.profileDays = profileDays
        self.quietHours = quietHours
    }

    /// Whether the shape moved the answer at all, rather than reducing to the flat clock.
    public var isShaped: Bool { profileDays > 0 || abs(activityMultiplier - 1) > 0.01 }

    /// The share of the horizon's expected activity accrued by each point in `[from, to]`.
    ///
    /// A forecast plotted against this rather than against the clock climbs when the account
    /// works and levels off when it sleeps, and its endpoint is unchanged. Everything the chart
    /// draws forward — the dashed centre and the cone around it — is reparameterized by the same
    /// fractions, so the interval cannot end up narrower than the line it is meant to contain.
    public func progress(
        from: Date, to: Date, maximumPoints: Int = 96, calendar: Calendar = .current
    ) -> [(t: Date, fraction: Double)] {
        guard remainingMass > 0, from < to else { return [] }
        return profile.massCheckpoints(
            from: from, to: to, multiplier: activityMultiplier, persistence: persistence,
            maximumPoints: maximumPoints, calendar: calendar
        )
        .map { (t: $0.t, fraction: min(max($0.mass / remainingMass, 0), 1)) }
    }

    /// What the wall-clock pacing this replaced would have projected: the reading divided by the
    /// hours the window has been open, carried across the hours it has left.
    ///
    /// Carried so the row can show its own working. The activity clock can move a forecast by
    /// several points without any single clause below being large enough to mention — this
    /// account's live weekly reading came out 7 points higher than the clock while its horizon was
    /// only a tenth busier than average, because the *elapsed* side of the ratio had moved too.
    /// Stating the number it replaced is the one explanation that is never suppressed by its own
    /// arithmetic.
    public var flatProjectedAtReset: Double? {
        guard elapsedHours > 0, remainingHours >= 0, elapsedMass > 0, ratePerMass.isFinite
        else { return nil }
        let current = ratePerMass * elapsedMass
        let projected = current + (current / elapsedHours) * remainingHours
        return projected.isFinite ? projected : nil
    }

    /// How much of the remaining horizon the profile expects to be worked, as a share of the same
    /// stretch of average hours. Below 1 means the window resets across quieter time than usual —
    /// a weekend, a night, or both.
    public var remainingIntensity: Double? {
        guard remainingHours > 0, remainingMass.isFinite else { return nil }
        return remainingMass / remainingHours
    }
}

// MARK: - Day bucketing

/// Buckets instants into complete local days and local hours without a `Calendar` call per event.
///
/// `Calendar.startOfDay(for:)` and `Calendar.component(.hour, from:)` cost a few microseconds
/// each, which is nothing until a corpus multiplies it. Measured at 32,000 events — an ordinary
/// size for this app, which reads every transcript on the machine — bucketing per event that way
/// cost 160ms per profile, and `ProjectionEngine.project` builds one on every poll *on the main
/// actor*. Two windows made it a third of a second of dropped frames every three minutes.
///
/// So the calendar is consulted `days + 1` times, up front, for the day boundaries; every event
/// after that is a binary search over at most 29 instants and one division. Measured on the same
/// corpus this is under 5ms.
///
/// The hour is taken as the offset from the day's own local midnight, which is exact except on
/// the two days a year a local day is 23 or 25 hours long — where part of the day lands one
/// bucket out in a 28-day histogram. That is a rounding error in a shape that is deliberately
/// smoothed and shrunk; the *mass integrator* walks real calendar hours, because there a
/// misplaced hour would move a forecast rather than nudge a histogram.
struct LocalDayIndex {
    /// Ascending local midnights, one per complete day, oldest first.
    private let starts: [TimeInterval]
    /// Weekday index (0 = Sunday) for each day, precomputed alongside.
    private let weekdays: [Int]
    /// End of the last complete day — the start of today, which is partial and excluded.
    private let end: TimeInterval

    var dayCount: Int { starts.count }

    /// `days` complete local days ending with the one before `now`'s. Nil if the calendar cannot
    /// produce the boundaries, which leaves every caller on its flat-clock path.
    init?(days: Int, endingAt now: Date, calendar: Calendar) {
        guard days > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        var starts: [TimeInterval] = []
        var weekdays: [Int] = []
        starts.reserveCapacity(days)
        weekdays.reserveCapacity(days)
        for offset in stride(from: days, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let start = calendar.startOfDay(for: day)
            starts.append(start.timeIntervalSince1970)
            weekdays.append(max(0, min(6, calendar.component(.weekday, from: start) - 1)))
        }
        guard starts.count == days, starts.allSatisfy({ $0.isFinite }) else { return nil }
        self.starts = starts
        self.weekdays = weekdays
        self.end = today.timeIntervalSince1970
    }

    /// The day `date` falls in, or nil if it is outside the indexed span — including today, which
    /// is partial, and any timestamp from a machine whose clock runs fast.
    func day(of date: Date) -> Int? {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= starts[0], value < end else { return nil }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= value { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func hour(of date: Date, day: Int) -> Int {
        let offset = (date.timeIntervalSince1970 - starts[day]) / 3600
        return max(0, min(23, Int(offset)))
    }

    func weekday(of day: Int) -> Int { weekdays[day] }
}
