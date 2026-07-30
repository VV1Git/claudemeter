import Foundation

// MARK: - Model rate

/// Published per-million-token rates for one model.
///
/// Only the two base rates are stored: the cache rates are fixed multiples of the
/// model's input rate, so deriving them keeps a model's five numbers from ever
/// drifting out of agreement with each other.
public struct ModelRate: Sendable, Equatable {
    /// The published multiples of a model's base input rate.
    ///
    /// Named rather than inlined because `ProjectionEngine.weight` needs the same ratios to
    /// weight tokens by relative spend. Two copies of 1.25 and 2.0 in separate files is one
    /// copy too many: the burn rate would keep pricing cache writes the old way for as long
    /// as it took someone to notice.
    public static let cacheWrite5mMultiple: Double = 1.25
    public static let cacheWrite1hMultiple: Double = 2.0
    public static let cacheReadMultiple: Double = 0.10
    /// Every model in the table prices output at five times its input rate.
    public static let outputMultiple: Double = 5.0

    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }

    /// Cache write with the 5-minute TTL: 1.25× the base input rate.
    public var cacheWrite5mPerMTok: Double { inputPerMTok * Self.cacheWrite5mMultiple }

    /// Cache write with the 1-hour TTL: 2× the base input rate.
    public var cacheWrite1hPerMTok: Double { inputPerMTok * Self.cacheWrite1hMultiple }

    /// Cache read: 0.1× the base input rate.
    public var cacheReadPerMTok: Double { inputPerMTok * Self.cacheReadMultiple }
}

// MARK: - Pricing

/// Cost-equivalence for locally observed token usage.
///
/// A subscription isn't billed per token, so nothing here is a bill — it is the
/// equivalent spend at published API rates, which is the only figure that makes usage
/// across models comparable.
public enum Pricing {
    /// Sonnet 5 introductory pricing ends at the end of this day (inclusive).
    public static let sonnet5IntroEnd: Date = ISO8601.date(from: "2026-08-31T23:59:59Z")!

    /// First instant of standard Sonnet 5 pricing, derived from `sonnet5IntroEnd` so the
    /// two can never disagree. Compared with `<` rather than testing `<= sonnet5IntroEnd`
    /// so that any instant on 2026-08-31 stays inside the window: transcript timestamps
    /// carry milliseconds, so `2026-08-31T23:59:59.500Z` is a real value that a `<=`
    /// against the 23:59:59 boundary would misprice.
    private static let sonnet5IntroCutoff: Date = sonnet5IntroEnd.addingTimeInterval(1)

    /// The introductory rate is the *base* input rate while the window is open, so the cache
    /// multiples hang off $2.00 and not off the standard $3.00 — cache reads bill at $0.20/MTok,
    /// 5-minute writes at $2.50, 1-hour writes at $4.00. Checked against the published tables
    /// rather than assumed, because it is the single largest lever on the figure this app
    /// shows: deriving the cache rates from the standard price instead would move a corpus
    /// dominated by Sonnet 5 cache reads by roughly a sixth.
    private static let sonnet5Intro = ModelRate(inputPerMTok: 2.00, outputPerMTok: 10.00)

    /// Standard published rates, per million tokens.
    private static let standardRates: [String: ModelRate] = [
        "claude-opus-5": ModelRate(inputPerMTok: 5.00, outputPerMTok: 25.00),
        "claude-opus-4-8": ModelRate(inputPerMTok: 5.00, outputPerMTok: 25.00),
        "claude-opus-4-7": ModelRate(inputPerMTok: 5.00, outputPerMTok: 25.00),
        "claude-opus-4-6": ModelRate(inputPerMTok: 5.00, outputPerMTok: 25.00),
        "claude-sonnet-5": ModelRate(inputPerMTok: 3.00, outputPerMTok: 15.00),
        "claude-sonnet-4-6": ModelRate(inputPerMTok: 3.00, outputPerMTok: 15.00),
        "claude-haiku-4-5": ModelRate(inputPerMTok: 1.00, outputPerMTok: 5.00),
        "claude-fable-5": ModelRate(inputPerMTok: 10.00, outputPerMTok: 50.00),
    ]

    private static let tokensPerMTok = 1_000_000.0

    /// `nil` for `<synthetic>` and unrecognised ids.
    ///
    /// `date` matters because introductory pricing is a window, not a property of the
    /// model: historical events must be costed at the rate in force when they happened.
    public static func rate(for model: String, on date: Date) -> ModelRate? {
        let id = canonical(model)
        if id == "claude-sonnet-5", date < sonnet5IntroCutoff {
            return sonnet5Intro
        }
        return standardRates[id]
    }

    /// A model id with any dated alias suffix removed: `claude-opus-4-5-20251101` keys the
    /// same rate as `claude-opus-4-5`.
    ///
    /// Transcripts carry whichever form the request was made with, and the table holds only
    /// the undated one. Without this, a pinned or dated id misses the lookup and prices at
    /// nothing — while `ModelUsage.displayName`, which already strips date suffixes, still
    /// labels the row with the correct model name. The result would be a row that looks
    /// entirely normal and reads $0.00.
    static func canonical(_ model: String) -> String {
        guard let marker = model.lastIndex(of: "-") else { return model }
        let suffix = model[model.index(after: marker)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isNumber) else { return model }
        return String(model[..<marker])
    }

    /// Whether this app knows what `model` costs. False means any cost shown for it is a
    /// floor, not a figure — see `cost(_:model:on:)`, which charges an unknown model nothing.
    public static func isPriced(_ model: String, on date: Date) -> Bool {
        rate(for: model, on: date) != nil
    }

    /// Equivalent cost in USD at published API rates. 0 when the model has no rate.
    public static func cost(_ tokens: TokenCounts, model: String, on date: Date) -> Double {
        guard let rate = rate(for: model, on: date) else { return 0 }

        // `cacheCreate` is the *total* of the two TTL buckets, so pricing it in addition
        // to `cacheCreate5m` + `cacheCreate1h` would charge every cache write twice. The
        // split is what gets priced; whatever the split fails to account for is charged at
        // the 5-minute rate, which is both the cheaper write and the API default TTL.
        let split = tokens.cacheCreate5m + tokens.cacheCreate1h
        let unsplitCreate = max(0, tokens.cacheCreate - split)

        var dollars = 0.0
        dollars += Double(tokens.input) / tokensPerMTok * rate.inputPerMTok
        dollars += Double(tokens.output) / tokensPerMTok * rate.outputPerMTok
        dollars += Double(tokens.cacheRead) / tokensPerMTok * rate.cacheReadPerMTok
        dollars += Double(tokens.cacheCreate5m + unsplitCreate) / tokensPerMTok * rate.cacheWrite5mPerMTok
        dollars += Double(tokens.cacheCreate1h) / tokensPerMTok * rate.cacheWrite1hPerMTok
        return dollars
    }

    /// The model id the transcripts use for rows that never reached a real model.
    /// Excluded from all token and cost math.
    public static let syntheticModel = "<synthetic>"
}
