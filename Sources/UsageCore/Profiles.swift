import Foundation

// MARK: - Pace against this account's own norm

/// This cycle's spend so far against what the same fraction of previous cycles had spent.
///
/// The comparison is at equal *elapsed fraction*, never at equal wall-clock totals: three days
/// into a week is not comparable with a finished week, and the question worth answering is
/// whether this cycle is running hot for how far through it is.
///
/// Measured in weighted tokens from local transcripts rather than in limit percentages, which
/// is what makes it usable at all. The poll series is only ever a couple of windows deep — it
/// is pruned to keep the app's storage bounded — while the transcripts reach back as far as
/// Claude Code has been writing them, so the token history covers many cycles where the
/// percentage history covers barely one.
public struct CyclePace: Sendable, Equatable {
    /// Weighted tokens spent since this cycle opened.
    public let current: Double
    /// Median of the previous cycles' spend at this same elapsed fraction.
    public let typical: Double
    /// How many previous cycles that median was taken over.
    public let priorCycles: Int
    /// How far into the cycle the comparison was made, 0...1.
    public let elapsedFraction: Double

    public init(current: Double, typical: Double, priorCycles: Int, elapsedFraction: Double) {
        self.current = current
        self.typical = typical
        self.priorCycles = priorCycles
        self.elapsedFraction = elapsedFraction
    }

    /// Current spend as a multiple of typical. `nil` when the norm is zero, which is not a
    /// ratio — an account with no comparable history is not "infinitely ahead".
    public var ratio: Double? {
        guard typical > 0, current.isFinite, typical.isFinite else { return nil }
        return current / typical
    }

    /// Signed share above or below the norm, for a `+18%` / `−24%` reading.
    public var deviation: Double? {
        ratio.map { $0 - 1 }
    }
}

// MARK: - Hour-of-day profile

/// Weighted spend bucketed by local hour of day.
public struct HourBucket: Sendable, Equatable, Identifiable {
    public let hour: Int
    public let weighted: Double

    public var id: Int { hour }

    public init(hour: Int, weighted: Double) {
        self.hour = hour
        self.weighted = weighted
    }
}

extension Aggregates {
    /// Fewest previous cycles worth taking a median over.
    public static let minimumPriorCycles = 2
    /// Most previous cycles to look back over. Beyond about this, behaviour from two months ago
    /// is not evidence about this week.
    public static let maximumPriorCycles = 8

    /// This cycle's spend against the median of previous cycles at the same elapsed fraction.
    ///
    /// A prior cycle only counts when the transcripts actually cover it: the earliest recorded
    /// event bounds how far back the comparison can honestly reach, and a cycle that predates
    /// the record would otherwise contribute a spurious zero and drag the norm down.
    public static func cyclePace(
        events: [UsageEvent], kind: WindowKind, resetsAt: Date, now: Date
    ) -> CyclePace? {
        let length = kind.nominalDuration
        let cycleStart = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(cycleStart)
        guard elapsed > 0, elapsed <= length else { return nil }

        let spend = events
            .filter { $0.model != Pricing.syntheticModel }
            .sorted { $0.timestamp < $1.timestamp }
        guard let earliest = spend.first?.timestamp else { return nil }

        func weighted(from start: Date, to end: Date) -> Double {
            spend
                .filter { $0.timestamp > start && $0.timestamp <= end }
                .reduce(0.0) { $0 + LimitWeight.of($1.tokens) }
        }

        var priors: [Double] = []
        for step in 1...maximumPriorCycles {
            let start = cycleStart.addingTimeInterval(-Double(step) * length)
            guard start >= earliest else { break }
            priors.append(weighted(from: start, to: start.addingTimeInterval(elapsed)))
        }
        guard priors.count >= minimumPriorCycles else { return nil }

        let sorted = priors.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

        return CyclePace(
            current: weighted(from: cycleStart, to: now),
            typical: median,
            priorCycles: priors.count,
            elapsedFraction: elapsed / length)
    }

    /// Weighted spend by local hour of day over the trailing `days`, zero-filled to 24 buckets.
    ///
    /// Zero-filled because an hour with no work is a real fact about when this account is used,
    /// and dropping it would leave a chart that silently rescaled its own x-axis.
    public static func hourProfile(
        events: [UsageEvent], days: Int, now: Date, calendar: Calendar = .current
    ) -> [HourBucket] {
        guard days > 0,
            let cutoff = calendar.date(
                byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
        else { return [] }

        var totals = [Double](repeating: 0, count: 24)
        for event in events
        where event.model != Pricing.syntheticModel && event.timestamp >= cutoff
            && event.timestamp <= now
        {
            let hour = calendar.component(.hour, from: event.timestamp)
            guard hour >= 0, hour < 24 else { continue }
            totals[hour] += LimitWeight.of(event.tokens)
        }
        return totals.enumerated().map { HourBucket(hour: $0.offset, weighted: $0.element) }
    }

    /// Share of weighted spend that went to sub-agents rather than to the main conversation.
    ///
    /// Weighted rather than raw, so it answers the question that matters — how much of the
    /// limit sub-agents are consuming — instead of how many tokens they happened to move.
    public static func sidechainShare(from events: [UsageEvent]) -> Double {
        var total = 0.0
        var sidechain = 0.0
        for event in events where event.model != Pricing.syntheticModel {
            let weight = LimitWeight.of(event.tokens)
            total += weight
            if event.isSidechain { sidechain += weight }
        }
        guard total > 0 else { return 0 }
        return sidechain / total
    }
}
