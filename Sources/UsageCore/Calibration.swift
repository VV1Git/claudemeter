import Foundation

// MARK: - Limit weighting

/// How much of a rate limit a bundle of tokens consumes, in arbitrary units.
///
/// Rate limits track something closer to spend than to raw token count, so tokens are weighted
/// by their relative API price: output is the expensive side, cache reads a tenth of fresh
/// input, cache writes a quarter more. The absolute scale is meaningless and cancels out
/// wherever this is used — only the *ratios* matter — which is why it deliberately does not
/// depend on per-model rates.
///
/// The multiples are `ModelRate`'s rather than literals, so a pricing change cannot leave two
/// callers weighting tokens differently. Lives here rather than inside `ProjectionEngine`
/// because the burn-rate fit, the limit calibration and the usage profiles all need the same
/// definition, and three private copies would be three chances to drift.
public enum LimitWeight {
    public static func of(_ tokens: TokenCounts) -> Double {
        let split = tokens.cacheCreate5m + tokens.cacheCreate1h
        let cacheWrite = split > 0
            ? Double(tokens.cacheCreate5m) * ModelRate.cacheWrite5mMultiple
                + Double(tokens.cacheCreate1h) * ModelRate.cacheWrite1hMultiple
            : Double(tokens.cacheCreate) * ModelRate.cacheWrite5mMultiple
        return Double(tokens.input)
            + Double(tokens.output) * ModelRate.outputMultiple
            + Double(tokens.cacheRead) * ModelRate.cacheReadMultiple
            + cacheWrite
    }

    /// The model family a transcript's model string belongs to — `Opus`, `Sonnet`, and so on.
    ///
    /// Families rather than exact models: `claude-opus-5` and `claude-opus-4-8` consume a limit
    /// at rates far closer to each other than either is to Sonnet, and splitting by exact model
    /// would scatter an already thin sample across versions that answer the same question.
    public static func family(of model: String) -> String? {
        let lowered = model.lowercased()
        for family in ["opus", "sonnet", "haiku", "fable"] where lowered.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        return nil
    }
}

// MARK: - Limit calibration

/// The exchange rate between a limit's percentage points and the work that consumed them.
///
/// This is the one figure neither data source can produce alone. The API reports utilization
/// and never says what it counted; the transcripts report tokens and never say what a limit
/// costs. Matched interval by interval — how many points did this window gain while these
/// tokens were being spent — they give a rate, and that rate converts an abstract "38% used"
/// into how much work is actually left.
///
/// Only local Claude Code transcripts are visible, so usage from claude.ai, the desktop app or
/// another machine raised the percentage without contributing any tokens here. Every rate below
/// is therefore a *floor* on the tokens a point really costs, and the headroom derived from it
/// is a floor on the work remaining. That direction is the safe one: the app under-promises
/// how much is left rather than over-promising.
public struct LimitCalibration: Sendable, Equatable {
    /// Weighted tokens per percentage point, over every interval where the window rose.
    public let weightedTokensPerPoint: Double
    public let intervals: Int
    public let pointsObserved: Double
    /// Per-family rates, present only for families with enough intervals of their own.
    public let families: [FamilyRate]

    public struct FamilyRate: Sendable, Equatable, Identifiable {
        public let family: String
        public let weightedTokensPerPoint: Double
        public let intervals: Int
        public let pointsObserved: Double

        public var id: String { family }

        public init(
            family: String, weightedTokensPerPoint: Double, intervals: Int, pointsObserved: Double
        ) {
            self.family = family
            self.weightedTokensPerPoint = weightedTokensPerPoint
            self.intervals = intervals
            self.pointsObserved = pointsObserved
        }
    }

    public init(
        weightedTokensPerPoint: Double, intervals: Int, pointsObserved: Double,
        families: [FamilyRate]
    ) {
        self.weightedTokensPerPoint = weightedTokensPerPoint
        self.intervals = intervals
        self.pointsObserved = pointsObserved
        self.families = families
    }

    /// Weighted tokens still available before `percent` reaches the cap.
    public func headroom(fromPercent percent: Double) -> Double? {
        guard percent.isFinite, weightedTokensPerPoint.isFinite, weightedTokensPerPoint > 0
        else { return nil }
        return max(0, 100 - max(0, percent)) * weightedTokensPerPoint
    }

    /// How many times more of the limit the dearest family consumes per weighted token than
    /// the cheapest. `nil` until at least two families have been measured separately.
    ///
    /// Two families is a high bar in practice and it is meant to be: the ratio is only
    /// identifiable if the account ran stretches dominated by each in turn. An account that
    /// always mixes them, or one whose recent work is all a single family — which is exactly
    /// what this account's retained samples show, every rising interval at least 80% Opus —
    /// leaves the two indistinguishable, and inventing a number from collinear data would be
    /// worse than saying so.
    public var familySpread: (cheapest: FamilyRate, dearest: FamilyRate, ratio: Double)? {
        let usable = families.filter { $0.weightedTokensPerPoint > 0 }
        guard usable.count >= 2,
            let dearest = usable.min(by: { $0.weightedTokensPerPoint < $1.weightedTokensPerPoint }),
            let cheapest = usable.max(by: { $0.weightedTokensPerPoint < $1.weightedTokensPerPoint }),
            cheapest.weightedTokensPerPoint > dearest.weightedTokensPerPoint
        else { return nil }
        // Fewer tokens per point means the family burns the limit faster, so the ratio is the
        // cheap family's token cost over the dear one's.
        return (
            cheapest, dearest,
            cheapest.weightedTokensPerPoint / dearest.weightedTokensPerPoint
        )
    }
}

extension ProjectionEngine {
    /// Intervals needed before a rate is worth quoting at all.
    public static let minimumCalibrationIntervals = 4
    /// Points needed alongside them. The API reports whole points, so three intervals that
    /// each moved by one carry three observations of a quantity rounded to the unit.
    public static let minimumCalibrationPoints: Double = 3
    /// Share of an interval's tokens one family must account for before the interval counts as
    /// evidence about that family rather than about the mix.
    public static let familyPurityThreshold: Double = 0.8
    /// Intervals a family needs before its own rate is reported.
    public static let minimumFamilyIntervals = 4

    /// Matches each rise in `kind`'s utilization against the tokens spent while it happened.
    ///
    /// Only rises count. A flat interval says nothing about the exchange rate, and on the
    /// rolling reading a *fall* is usage ageing out rather than being refunded — including it
    /// would net real spend against an artefact of the window sliding.
    ///
    /// Intervals spanning a reset are dropped: the percentage on the far side belongs to a
    /// different window, so the difference is not a rise at all.
    public static func calibrate(
        kind: WindowKind, samples: [Sample], events: [UsageEvent], now: Date
    ) -> LimitCalibration? {
        let ordered = samples
            .filter { $0.t <= now && $0.percent(for: kind) != nil }
            .sorted { $0.t < $1.t }
        guard ordered.count > 1 else { return nil }

        let spend = events
            .filter { $0.model != Pricing.syntheticModel }
            .sorted { $0.timestamp < $1.timestamp }

        var totalPoints = 0.0
        var totalWeight = 0.0
        var intervals = 0
        var familyPoints: [String: Double] = [:]
        var familyWeight: [String: Double] = [:]
        var familyIntervals: [String: Int] = [:]

        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            guard !isResetBoundary(previous, next, kind: kind),
                let before = previous.percent(for: kind), let after = next.percent(for: kind)
            else { continue }
            let gained = after - before
            guard gained > 0 else { continue }

            var byFamily: [String: Double] = [:]
            var weight = 0.0
            for event in spend where event.timestamp > previous.t && event.timestamp <= next.t {
                let value = LimitWeight.of(event.tokens)
                weight += value
                if let family = LimitWeight.family(of: event.model) {
                    byFamily[family, default: 0] += value
                }
            }
            guard weight > 0 else { continue }

            totalPoints += gained
            totalWeight += weight
            intervals += 1

            // The interval is evidence about one family only when that family did nearly all
            // of the work in it. Anything more mixed cannot attribute the rise.
            if let (family, share) = byFamily.max(by: { $0.value < $1.value }),
                share / weight >= familyPurityThreshold
            {
                familyPoints[family, default: 0] += gained
                familyWeight[family, default: 0] += weight
                familyIntervals[family, default: 0] += 1
            }
        }

        guard intervals >= minimumCalibrationIntervals, totalPoints >= minimumCalibrationPoints,
            totalWeight > 0
        else { return nil }

        let families = familyIntervals
            .filter { $0.value >= minimumFamilyIntervals }
            .compactMap { family, count -> LimitCalibration.FamilyRate? in
                guard let points = familyPoints[family], points > 0,
                    let weight = familyWeight[family], weight > 0
                else { return nil }
                return LimitCalibration.FamilyRate(
                    family: family, weightedTokensPerPoint: weight / points,
                    intervals: count, pointsObserved: points)
            }
            .sorted { $0.weightedTokensPerPoint < $1.weightedTokensPerPoint }

        return LimitCalibration(
            weightedTokensPerPoint: totalWeight / totalPoints,
            intervals: intervals,
            pointsObserved: totalPoints,
            families: families)
    }
}
