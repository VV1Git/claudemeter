import Foundation
import Testing

@testable import UsageCore

/// Pricing is pure arithmetic over a static table: no filesystem, network, or Keychain
/// access, so no `Paths` override is needed here.
struct PricingTests {

    // MARK: - Fixed instants

    /// Comfortably inside the Sonnet 5 introductory window.
    private static let insideIntro = ISO8601.date(from: "2026-07-29T19:23:56.813Z")!
    /// Last day of the introductory window.
    private static let introLastDay = ISO8601.date(from: "2026-08-31T12:00:00Z")!
    /// The documented final second of the window.
    private static let introFinalSecond = ISO8601.date(from: "2026-08-31T23:59:59Z")!
    /// First day of standard Sonnet 5 pricing.
    private static let afterIntro = ISO8601.date(from: "2026-09-01T00:00:00Z")!
    /// First instant of the final day of the window.
    private static let introFirstInstant = ISO8601.date(from: "2026-08-31T00:00:00Z")!
    /// Last representable instant of the final day, in the transcript timestamp shape.
    private static let introLastMillisecond = ISO8601.date(from: "2026-08-31T23:59:59.999Z")!
    /// A realistic transcript timestamp in the final second of the window.
    private static let introFinalSecondWithMillis = ISO8601.date(from: "2026-08-31T23:59:59.813Z")!
    /// One millisecond into standard pricing.
    private static let afterIntroFirstMillisecond = ISO8601.date(from: "2026-09-01T00:00:00.001Z")!
    /// 2026-08-31 in local terms at UTC−7, but 2026-09-01 in UTC.
    private static let lateAug31AtMinus7 = ISO8601.date(from: "2026-08-31T23:00:00-07:00")!
    /// 2026-09-01 in local terms at UTC+14, but still 2026-08-31 in UTC.
    private static let earlySep1AtPlus14 = ISO8601.date(from: "2026-09-01T13:00:00+14:00")!

    private static let cents = 1e-9

    // MARK: - Base rates

    @Test("Opus 5 is 5.00 / 25.00 per MTok")
    func opus5BaseRate() {
        let rate = Pricing.rate(for: "claude-opus-5", on: Self.insideIntro)
        #expect(rate == ModelRate(inputPerMTok: 5.00, outputPerMTok: 25.00))
    }

    @Test("The whole Opus family shares the 5.00 / 25.00 rate")
    func opusFamilyRates() {
        for model in ["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6"] {
            let rate = Pricing.rate(for: model, on: Self.insideIntro)
            #expect(rate?.inputPerMTok == 5.00, "\(model) input")
            #expect(rate?.outputPerMTok == 25.00, "\(model) output")
        }
    }

    @Test("Haiku 4.5 and Fable 5 carry their own rates")
    func haikuAndFableRates() {
        #expect(Pricing.rate(for: "claude-haiku-4-5", on: Self.insideIntro)
            == ModelRate(inputPerMTok: 1.00, outputPerMTok: 5.00))
        #expect(Pricing.rate(for: "claude-fable-5", on: Self.insideIntro)
            == ModelRate(inputPerMTok: 10.00, outputPerMTok: 50.00))
    }

    // MARK: - Sonnet 5 introductory window

    @Test("Sonnet 5 is 2.00 / 10.00 through 2026-08-31 and 3.00 / 15.00 from 2026-09-01")
    func sonnet5IntroWindowBoundary() {
        let intro = ModelRate(inputPerMTok: 2.00, outputPerMTok: 10.00)
        let standard = ModelRate(inputPerMTok: 3.00, outputPerMTok: 15.00)

        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.insideIntro) == intro)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.introLastDay) == intro)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.introFinalSecond) == intro)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.afterIntro) == standard)
    }

    @Test("sonnet5IntroEnd is the final second of 2026-08-31 UTC")
    func introEndConstant() {
        #expect(Pricing.sonnet5IntroEnd == Self.introFinalSecond)
        #expect(Pricing.sonnet5IntroEnd < Self.afterIntro)
        // Pinned as an absolute instant so the boundary cannot drift by a day, and so
        // the test cannot pass for the wrong reason on a machine in a non-UTC zone.
        #expect(Pricing.sonnet5IntroEnd.timeIntervalSince1970 == 1_788_220_799)
    }

    @Test("The intro window covers all of 2026-08-31 UTC, to the millisecond")
    func introWindowCoversWholeFinalDayUTC() {
        let intro = ModelRate(inputPerMTok: 2.00, outputPerMTok: 10.00)
        let standard = ModelRate(inputPerMTok: 3.00, outputPerMTok: 15.00)

        // First instant of the final day.
        #expect(Self.introFirstInstant.timeIntervalSince1970 == 1_788_134_400)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.introFirstInstant) == intro)

        // Transcripts carry 3 fractional digits, so sub-second instants past 23:59:59
        // are real inputs — they must still be inside the window.
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.introLastMillisecond) == intro)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.introFinalSecondWithMillis) == intro)

        // The very next millisecond is standard.
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.afterIntroFirstMillisecond) == standard)
        #expect(Self.afterIntro.timeIntervalSince1970 == 1_788_220_800)
    }

    @Test("The boundary is a UTC instant, not a local calendar day")
    func introBoundaryIsTimezoneIndependent() {
        // 2026-08-31T23:00:00-07:00 is still 2026-08-31 *locally* but 2026-09-01 in UTC,
        // and the boundary is fixed in UTC — so it prices as standard. Both instants are
        // built from explicit offsets rather than the machine's zone, so these hold
        // wherever the suite runs.
        #expect(Self.lateAug31AtMinus7 > Pricing.sonnet5IntroEnd)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.lateAug31AtMinus7)?.inputPerMTok == 3.00)

        // The mirror case: 2026-09-01 local at UTC+14 is still 2026-08-31 in UTC.
        #expect(Self.earlySep1AtPlus14 < Pricing.sonnet5IntroEnd)
        #expect(Pricing.rate(for: "claude-sonnet-5", on: Self.earlySep1AtPlus14)?.inputPerMTok == 2.00)
    }

    @Test("The intro window applies only to Sonnet 5")
    func introWindowDoesNotLeakToOtherModels() {
        let standardSonnet = ModelRate(inputPerMTok: 3.00, outputPerMTok: 15.00)
        #expect(Pricing.rate(for: "claude-sonnet-4-6", on: Self.introLastDay) == standardSonnet)
        #expect(Pricing.rate(for: "claude-sonnet-4-6", on: Self.afterIntro) == standardSonnet)
        #expect(Pricing.rate(for: "claude-opus-5", on: Self.introLastDay)?.inputPerMTok == 5.00)
    }

    @Test("Cost picks up the intro rate inside the window and the standard rate after")
    func costFollowsTheIntroWindow() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)
        // Intro: 1M × 2.00 + 1M × 10.00
        let intro = Pricing.cost(tokens, model: "claude-sonnet-5", on: Self.introFinalSecond)
        #expect(abs(intro - 12.00) < Self.cents)
        // Standard: 1M × 3.00 + 1M × 15.00
        let standard = Pricing.cost(tokens, model: "claude-sonnet-5", on: Self.afterIntro)
        #expect(abs(standard - 18.00) < Self.cents)
    }

    // MARK: - Cache multipliers

    @Test("Opus 5 cache multipliers are exact: 0.50 read, 6.25 write-5m, 10.00 write-1h")
    func opus5CacheMultipliers() throws {
        let rate = try #require(Pricing.rate(for: "claude-opus-5", on: Self.insideIntro))
        #expect(abs(rate.cacheReadPerMTok - 0.50) < Self.cents)
        #expect(abs(rate.cacheWrite5mPerMTok - 6.25) < Self.cents)
        #expect(abs(rate.cacheWrite1hPerMTok - 10.00) < Self.cents)
    }

    @Test("Cache multipliers derive from the *effective* input rate, intro included")
    func introRateCacheMultipliers() throws {
        let rate = try #require(Pricing.rate(for: "claude-sonnet-5", on: Self.introLastDay))
        #expect(abs(rate.cacheReadPerMTok - 0.20) < Self.cents)
        #expect(abs(rate.cacheWrite5mPerMTok - 2.50) < Self.cents)
        #expect(abs(rate.cacheWrite1hPerMTok - 4.00) < Self.cents)
    }

    // MARK: - Unpriced models

    @Test("<synthetic> has no rate and contributes no cost")
    func syntheticIsUnpriced() {
        let tokens = TokenCounts(input: 5_000_000, output: 5_000_000, cacheCreate: 1_000_000,
                                 cacheRead: 9_000_000, cacheCreate5m: 1_000_000)
        #expect(Pricing.rate(for: "<synthetic>", on: Self.insideIntro) == nil)
        #expect(Pricing.cost(tokens, model: "<synthetic>", on: Self.insideIntro) == 0)
        #expect(Pricing.syntheticModel == "<synthetic>")
    }

    @Test("An unrecognised model id has no rate and contributes no cost")
    func unknownModelIsUnpriced() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)
        #expect(Pricing.rate(for: "claude-imaginary-9", on: Self.insideIntro) == nil)
        #expect(Pricing.cost(tokens, model: "claude-imaginary-9", on: Self.insideIntro) == 0)
        #expect(Pricing.rate(for: "", on: Self.insideIntro) == nil)
    }

    // MARK: - Cost arithmetic

    @Test("A multi-field TokenCounts sums to the hand-computed total")
    func handComputedMultiFieldTotal() {
        // Opus 5: input 5.00, output 25.00, read 0.50, write-5m 6.25, write-1h 10.00.
        let tokens = TokenCounts(
            input: 1_000_000,       // 1.0 × 5.00  =  5.00
            output: 1_000_000,      // 1.0 × 25.00 = 25.00
            cacheCreate: 300_000,   // total of the two buckets below — not priced again
            cacheRead: 2_000_000,   // 2.0 × 0.50  =  1.00
            cacheCreate5m: 200_000, // 0.2 × 6.25  =  1.25
            cacheCreate1h: 100_000  // 0.1 × 10.00 =  1.00
        )
        let cost = Pricing.cost(tokens, model: "claude-opus-5", on: Self.insideIntro)
        #expect(abs(cost - 33.25) < Self.cents)
    }

    @Test("A fully split cacheCreate is priced once, not twice")
    func splitCacheCreateIsNotDoubleCounted() {
        let split = TokenCounts(cacheCreate: 300_000, cacheCreate5m: 200_000, cacheCreate1h: 100_000)
        let cost = Pricing.cost(split, model: "claude-opus-5", on: Self.insideIntro)
        // 0.2 × 6.25 + 0.1 × 10.00 = 2.25 — the 300_000 total adds nothing.
        #expect(abs(cost - 2.25) < Self.cents)

        // Same split with the total left unreported must cost the same.
        let withoutTotal = TokenCounts(cacheCreate5m: 200_000, cacheCreate1h: 100_000)
        let sameCost = Pricing.cost(withoutTotal, model: "claude-opus-5", on: Self.insideIntro)
        #expect(abs(sameCost - cost) < Self.cents)
    }

    @Test("cacheCreate with no 5m/1h split falls back to the 5-minute rate")
    func unsplitCacheCreateUsesFiveMinuteRate() {
        let tokens = TokenCounts(cacheCreate: 400_000)
        let cost = Pricing.cost(tokens, model: "claude-opus-5", on: Self.insideIntro)
        // 0.4 × 6.25 = 2.50
        #expect(abs(cost - 2.50) < Self.cents)

        // The fallback must be the 5-minute rate, not the 1-hour rate.
        let atOneHourRate = 0.4 * 10.00
        #expect(abs(cost - atOneHourRate) > Self.cents)
    }

    @Test("A partially split cacheCreate prices the remainder at the 5-minute rate")
    func partiallySplitCacheCreateChargesRemainder() {
        // Dedup takes the element-wise MAX of each token field, so a row can end up with
        // a `cacheCreate` total that its 5m/1h split does not fully account for. The
        // unaccounted remainder is charged at the 5-minute rate rather than dropped.
        let partial = TokenCounts(cacheCreate: 1_000_000, cacheCreate5m: 400_000)
        let cost = Pricing.cost(partial, model: "claude-opus-5", on: Self.insideIntro)
        // 0.4 × 6.25 (reported 5m) + 0.6 × 6.25 (remainder) = 6.25
        #expect(abs(cost - 6.25) < Self.cents)
        // Dropping the remainder would undercharge to 2.50.
        #expect(abs(cost - 2.50) > Self.cents)

        // Same with the remainder falling outside a reported 1-hour bucket.
        let withHour = TokenCounts(cacheCreate: 1_000_000, cacheCreate5m: 200_000,
                                   cacheCreate1h: 300_000)
        let hourCost = Pricing.cost(withHour, model: "claude-opus-5", on: Self.insideIntro)
        // 0.2 × 6.25 + 0.3 × 10.00 + 0.5 × 6.25 (remainder) = 1.25 + 3.00 + 3.125
        #expect(abs(hourCost - 7.375) < Self.cents)
    }

    @Test("A split larger than the reported total never subtracts cost")
    func overReportedSplitDoesNotGoNegative() {
        // The other side of the MAX-merge: the split can exceed the total. The remainder
        // clamps at zero instead of crediting the difference back.
        let overReported = TokenCounts(cacheCreate: 100_000, cacheCreate5m: 400_000,
                                       cacheCreate1h: 200_000)
        let cost = Pricing.cost(overReported, model: "claude-opus-5", on: Self.insideIntro)
        // 0.4 × 6.25 + 0.2 × 10.00 = 2.50 + 2.00 = 4.50, with no negative remainder.
        #expect(abs(cost - 4.50) < Self.cents)
        #expect(cost > 0)
    }

    @Test("Zero tokens cost nothing on a priced model")
    func zeroTokensCostNothing() {
        #expect(Pricing.cost(.zero, model: "claude-opus-5", on: Self.insideIntro) == 0)
    }

    @Test("Cost scales linearly with token count")
    func costScalesLinearly() {
        let single = TokenCounts(input: 100_000, output: 50_000, cacheRead: 400_000)
        let doubled = single + single
        let a = Pricing.cost(single, model: "claude-haiku-4-5", on: Self.insideIntro)
        let b = Pricing.cost(doubled, model: "claude-haiku-4-5", on: Self.insideIntro)
        #expect(abs(b - 2 * a) < Self.cents)
        // Haiku 4.5: 0.1 × 1.00 + 0.05 × 5.00 + 0.4 × 0.10 = 0.39
        #expect(abs(a - 0.39) < Self.cents)
    }
}
