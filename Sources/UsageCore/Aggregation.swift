import Foundation

// MARK: - Aggregation

/// Every rollup the panel shows, computed in one pass-set and carried back as plain values.
///
/// It exists to be computed somewhere other than the main actor. The individual functions in
/// `Aggregates` were always pure, but the *calling* of them lived in `AppModel` and therefore ran
/// on the main actor: eight traversals of the whole corpus, three of which sort it and one of
/// which prices every event four times over, on every poll, every rescan and every increment of
/// the idle-gap slider.
///
/// Honest about the size of the win: measured at 32,000 events in a release build this is around
/// four milliseconds, so it was never the thing that made the panel hang — that was the Keychain,
/// and it is fixed in `CredentialStore`. What moving it off buys is a bound rather than a
/// speed-up. The cost is linear in corpus size and the corpus only grows, whereas the main actor
/// has a 16ms budget; work that runs on every slider increment should not be one order of
/// magnitude from the frame budget and pointed the wrong way.
///
/// Gathering the results into one `Sendable` value is what makes the work movable — a detached
/// task computes this and the main actor assigns it in a single hop, instead of eight separate
/// pieces of state being written from inside the computation.
public struct Aggregation: Sendable {
    public let sessions: [SessionStat]
    public let daily: [DailyStat]
    public let models: [ModelUsage]
    public let efforts: [EffortUsage]
    public let usageHours: UsageHours?
    public let cacheHitRatio: Double
    public let sidechainShare: Double
    public let hourProfile: [HourBucket]
    public let eventCount: Int

    /// Days of history behind the daily bars.
    public static let dailyHistoryDays = 30
    /// Trailing days behind the hour-of-day profile. Long enough that one unusual night does not
    /// define the shape, short enough that a change of working hours shows up.
    public static let hourProfileDays = 30

    /// Deliberately does *not* include the calibration figures, even though it holds everything
    /// they need. Two entry points computing the same three values means two background tasks
    /// writing the same three pieces of state, and a scan-triggered pass and a poll-triggered one
    /// can then land in either order — leaving the exchange rate computed from the older sample
    /// series. `CalibrationOutcome` has exactly one producer instead, which makes its
    /// cancel-and-replace the whole of the ordering rule.
    public static func compute(
        events: [UsageEvent],
        gap: TimeInterval,
        now: Date
    ) -> Aggregation {
        // `effortSplit`, `usageHours` and `cacheHitRatio` take no `now` and so count every event
        // handed to them, unlike the ones that do. A transcript written by a machine whose clock
        // runs fast would stretch wall clock and agent hours without bound, so the clamp the
        // others apply internally is applied once here, on behalf of all of them — and filtering
        // once rather than per-function is also several fewer copies of a large array.
        let settled = events.filter { $0.timestamp <= now }

        return Aggregation(
            sessions: Aggregates.sessions(from: settled, idleGap: gap, now: now),
            daily: Aggregates.daily(
                from: settled, days: dailyHistoryDays, calendar: .current, now: now),
            models: Aggregates.modelSplit(from: settled, now: now),
            efforts: Aggregates.effortSplit(from: settled),
            usageHours: settled.isEmpty ? nil : Aggregates.usageHours(from: settled, gap: gap),
            cacheHitRatio: Aggregates.cacheHitRatio(from: settled),
            sidechainShare: Aggregates.sidechainShare(from: settled),
            hourProfile: Aggregates.hourProfile(
                events: settled, days: hourProfileDays, now: now, calendar: .current),
            eventCount: settled.count)
    }
}

/// The three figures that need both data sources at once — the poll series for what the limits
/// did, the transcripts for what was spent while they did it.
///
/// Computed on their own rather than as part of `Aggregation` because they are the only part a
/// *poll* changes: a new sample moves the exchange rate while nothing about the transcripts has
/// moved. Recomputing the whole rollup every three minutes would be several times the work for
/// one changed input.
public struct CalibrationOutcome: Sendable {
    public let fiveHour: LimitCalibration?
    public let sevenDay: LimitCalibration?
    public let cyclePace: CyclePace?

    public init(fiveHour: LimitCalibration?, sevenDay: LimitCalibration?, cyclePace: CyclePace?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.cyclePace = cyclePace
    }

    public static func compute(
        events: [UsageEvent],
        samples: [Sample],
        sevenDayResetsAt: Date?,
        now: Date
    ) -> CalibrationOutcome {
        // Same clamp as `Aggregation.compute`, and for the same reason: a transcript written by a
        // machine whose clock runs fast must not count toward spend that has not happened yet.
        let settled = events.filter { $0.timestamp <= now }
        return CalibrationOutcome(
            fiveHour: ProjectionEngine.calibrate(
                kind: .fiveHour, samples: samples, events: settled, now: now),
            sevenDay: ProjectionEngine.calibrate(
                kind: .sevenDay, samples: samples, events: settled, now: now),
            cyclePace: sevenDayResetsAt.flatMap {
                Aggregates.cyclePace(events: settled, kind: .sevenDay, resetsAt: $0, now: now)
            })
    }
}
