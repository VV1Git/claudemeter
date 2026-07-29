import Foundation

// MARK: - Model rate

/// Published per-million-token rates for one model.
///
/// Only the two base rates are stored: the cache rates are fixed multiples of the
/// model's input rate, so deriving them keeps a model's five numbers from ever
/// drifting out of agreement with each other.
public struct ModelRate: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }

    /// Cache write with the 5-minute TTL: 1.25× the base input rate.
    public var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }

    /// Cache write with the 1-hour TTL: 2× the base input rate.
    public var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }

    /// Cache read: 0.1× the base input rate.
    public var cacheReadPerMTok: Double { inputPerMTok * 0.10 }
}

// MARK: - Pricing

/// Cost-equivalence for locally observed token usage.
///
/// A Max subscription isn't billed per token, so nothing here is a bill — it is the
/// equivalent spend at published API rates, which is the only figure that makes usage
/// across models comparable.
public enum Pricing {
    /// Sonnet 5 introductory pricing ends at the end of this day (inclusive).
    public static let sonnet5IntroEnd: Date = ISO8601.date(from: "2026-08-31T23:59:59Z")!

    /// First instant of standard Sonnet 5 pricing, derived from `sonnet5IntroEnd` so the
    /// two can never disagree. Compared with `<` rather than testing `<= sonnet5IntroEnd`
    /// so that any instant on 2026-08-31 stays inside the window: transcript timestamps
    /// carry milliseconds, so `2026-08-31T23:59:59.813Z` is a real value that a `<=`
    /// against the 23:59:59 boundary would misprice.
    private static let sonnet5IntroCutoff: Date = sonnet5IntroEnd.addingTimeInterval(1)

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
        if model == "claude-sonnet-5", date < sonnet5IntroCutoff {
            return sonnet5Intro
        }
        return standardRates[model]
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
