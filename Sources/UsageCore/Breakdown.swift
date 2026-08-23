import Foundation

/// The figure a breakdown's heading carries: what every row beneath it adds up to.
public struct SplitTotal: Sendable, Equatable {
    public let tokens: TokenCounts
    /// `nil` when the split has nothing priced to report, so an unpriced heading cannot read as
    /// free. Every split has a cost today; the case remains representable because a split that
    /// cannot be priced is a real possibility, not because one of them is.
    public let cost: Double?

    public init(tokens: TokenCounts, cost: Double?) {
        self.tokens = tokens
        self.cost = cost
    }

    public static let zero = SplitTotal(tokens: .zero, cost: nil)
}

/// The totals shown above each split in the panel.
///
/// These exist as one named place, rather than as a `reduce` at each call site, for a reason
/// that is not tidiness: a heading that disagrees with the rows under it is worse than no
/// heading at all, and the way to disagree is to compute the total from a different expression
/// than the rows. Both now come from here, and the tests assert they sum.
///
/// The specific trap is `TokenCounts`: `cacheCreate` is the *total* of the two TTL buckets, so
/// anything that adds `cacheCreate5m` and `cacheCreate1h` on top of it counts every cache write
/// twice. `TokenCounts.total` already knows this; nothing here reimplements the sum.
public enum Breakdown {

    /// Totals for the model split. Cost is the sum of each model's own `costEquivalent`, which
    /// `Aggregates` priced at each event's own timestamp — so a corpus spanning a rate change
    /// keeps the rate that was in force when the tokens were spent.
    public static func total(models: [ModelUsage]) -> SplitTotal {
        SplitTotal(
            tokens: models.reduce(TokenCounts.zero) { $0 + $1.tokens },
            cost: models.reduce(0) { $0 + $1.costEquivalent })
    }

    /// Totals for the effort split. Same events as the model split, pooled by effort instead —
    /// so this cost and `total(models:)`'s are the same number reached two ways.
    public static func total(efforts: [EffortUsage]) -> SplitTotal {
        SplitTotal(
            tokens: efforts.reduce(TokenCounts.zero) { $0 + $1.tokens },
            cost: efforts.reduce(0) { $0 + $1.costEquivalent })
    }

    /// Totals for the daily bars, so the section can say what the thirty days come to rather
    /// than leaving the reader to add up a chart.
    public static func total(daily: [DailyStat]) -> SplitTotal {
        SplitTotal(
            tokens: daily.reduce(TokenCounts.zero) { $0 + $1.tokens },
            cost: daily.reduce(0) { $0 + $1.costEquivalent })
    }

    /// The per-field costs behind the cost split, pooled across models.
    ///
    /// Summed from each model's `fieldCosts` rather than re-priced here: re-pricing the pooled
    /// totals at today's rate is what once made the rows stop summing to the total beside them.
    public static func fieldCosts(models: [ModelUsage]) -> FieldCosts {
        models.reduce(FieldCosts.zero) { $0 + $1.fieldCosts }
    }
}
