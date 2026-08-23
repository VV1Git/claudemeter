import Foundation
import Testing

import UsageCore

// The property under test throughout: a heading equals the rows beneath it. A total computed
// from a different expression than the rows is the failure mode these guard against, and it is
// not hypothetical — summing every field of `TokenCounts`, ephemeral buckets included, inflated
// a figure by 2.5% while looking perfectly reasonable.

private func counts(
    input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0,
    cacheCreate5m: Int = 0, cacheCreate1h: Int = 0
) -> TokenCounts {
    TokenCounts(
        input: input, output: output, cacheCreate: cacheCreate, cacheRead: cacheRead,
        cacheCreate5m: cacheCreate5m, cacheCreate1h: cacheCreate1h)
}

private let opus = ModelUsage(
    model: "claude-opus-5",
    tokens: counts(
        input: 1_000, output: 2_000, cacheCreate: 3_000, cacheRead: 40_000,
        cacheCreate5m: 2_500, cacheCreate1h: 500),
    messageCount: 10,
    costEquivalent: 12.5,
    fieldCosts: FieldCosts(input: 1, cacheRead: 4, cacheWrite: 2.5, output: 5))

private let sonnet = ModelUsage(
    model: "claude-sonnet-5",
    tokens: counts(
        input: 500, output: 700, cacheCreate: 1_000, cacheRead: 9_000,
        cacheCreate5m: 1_000),
    messageCount: 4,
    costEquivalent: 3.5,
    fieldCosts: FieldCosts(input: 0.5, cacheRead: 1, cacheWrite: 1, output: 1))

// MARK: - Models

@Test func theModelTotalIsTheSumOfItsRows() {
    let total = Breakdown.total(models: [opus, sonnet])

    #expect(total.tokens.input == 1_500)
    #expect(total.tokens.output == 2_700)
    #expect(total.tokens.cacheCreate == 4_000)
    #expect(total.tokens.cacheRead == 49_000)
    #expect(total.cost == 16.0)
}

@Test func theModelTotalDoesNotCountCacheWritesTwice() {
    // The bug this file exists for. `cacheCreate` is the total of the 5m and 1h buckets, so a
    // total that adds all three reports 3,000 cache-write tokens as 6,000.
    let total = Breakdown.total(models: [opus])
    #expect(total.tokens.total == 1_000 + 2_000 + 3_000 + 40_000)

    // Stated the other way round, so the intent survives a change to `TokenCounts.total`:
    // the ephemeral split is a breakdown of a field already counted, never an addition to it.
    #expect(total.tokens.cacheCreate5m + total.tokens.cacheCreate1h == total.tokens.cacheCreate)
}

@Test func theTokenSplitRowsSumToTheHeading() {
    // Exactly the four rows `tokenRows` draws.
    let total = Breakdown.total(models: [opus, sonnet]).tokens
    let rows = total.input + total.cacheRead + total.cacheCreate + total.output
    #expect(rows == total.total)
}

// MARK: - Cost

@Test func theCostSplitRowsSumToTheHeading() {
    let costs = Breakdown.fieldCosts(models: [opus, sonnet])
    let rows = costs.input + costs.cacheRead + costs.cacheWrite + costs.output
    #expect(abs(rows - costs.total) < 1e-9)
}

@Test func thePooledFieldCostsAgreeWithThePerModelCosts() {
    // `FieldCosts.total` is documented as equal to `costEquivalent` by construction. The two
    // headings sit inches apart in the panel — "models" priced one way and "cost share" the
    // other would be visible and wrong.
    let byField = Breakdown.fieldCosts(models: [opus, sonnet]).total
    let byModel = Breakdown.total(models: [opus, sonnet]).cost
    #expect(byModel != nil)
    #expect(abs(byField - (byModel ?? 0)) < 1e-9)
}

// MARK: - Effort

@Test func theEffortTotalReportsNoCost() {
    // Pricing does not vary by reasoning effort, so there is nothing to sum. Zero would read as
    // free; absent reads as "not a question this split answers".
    let total = Breakdown.total(efforts: [
        EffortUsage(effort: "high", messageCount: 3, tokens: counts(input: 100, output: 200)),
        EffortUsage(effort: nil, messageCount: 1, tokens: counts(input: 50)),
    ])
    #expect(total.tokens.input == 150)
    #expect(total.tokens.output == 200)
    #expect(total.cost == nil)
}

// MARK: - Daily

@Test func theDailyTotalIsTheSumOfTheBars() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let total = Breakdown.total(daily: [
        DailyStat(day: day, tokens: counts(input: 10, cacheRead: 90), costEquivalent: 1.25,
                  messageCount: 2),
        DailyStat(day: day.addingTimeInterval(86_400), tokens: counts(input: 5, cacheRead: 45),
                  costEquivalent: 0.75, messageCount: 1),
    ])
    #expect(total.tokens.input == 15)
    #expect(total.tokens.cacheRead == 135)
    #expect(total.cost == 2.0)
}

// MARK: - Nothing recorded

@Test func emptySplitsTotalToZeroRatherThanFailing() {
    #expect(Breakdown.total(models: []).tokens == .zero)
    #expect(Breakdown.total(models: []).cost == 0)
    #expect(Breakdown.total(efforts: []).tokens == .zero)
    #expect(Breakdown.total(daily: []).tokens == .zero)
    #expect(Breakdown.fieldCosts(models: []) == .zero)
}
