import Foundation
import Testing

@testable import UsageCore

/// `ProjectionEngine` is pure arithmetic over samples and events the caller supplies: no
/// filesystem, network, or Keychain access, so no `Paths` override is needed here.
struct ProjectionTests {

    // MARK: - Fixtures

    private static let now = ISO8601.date(from: "2026-07-29T20:00:00Z")!

    /// `count` samples ending at `now`, spaced `stepMinutes` apart, oldest first.
    private func samples(
        kind: WindowKind = .fiveHour,
        now: Date = ProjectionTests.now,
        stepMinutes: Double = 5,
        count: Int,
        resetsAt: Date? = nil,
        percent: (Int) -> Double
    ) -> [Sample] {
        (0..<count).map { index in
            let t = now.addingTimeInterval(-Double(count - 1 - index) * stepMinutes * 60)
            let value = percent(index)
            switch kind {
            case .fiveHour:
                return Sample(
                    t: t, fiveHourPct: value, fiveHourResetsAt: resetsAt,
                    sevenDayPct: nil, sevenDayResetsAt: nil)
            case .sevenDay:
                return Sample(
                    t: t, fiveHourPct: nil, fiveHourResetsAt: nil,
                    sevenDayPct: value, sevenDayResetsAt: resetsAt)
            }
        }
    }

    private func snapshot(
        fiveHour: LimitWindow? = nil, sevenDay: LimitWindow? = nil,
        fetchedAt: Date = ProjectionTests.now
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour, sevenDay: sevenDay, limits: [], extraUsage: nil,
            fetchedAt: fetchedAt)
    }

    private func event(
        _ key: String, at t: Date, output: Int, model: String = "claude-sonnet-5"
    ) -> UsageEvent {
        UsageEvent(
            key: key, timestamp: t, sessionId: "session-1", cwd: "/Users/x/proj",
            model: model, effort: nil, isSidechain: false, agentId: nil,
            tokens: TokenCounts(output: output))
    }

    // MARK: - Measured fit

    @Test("A clean 10 points/hour series recovers 10 and reports a measured basis")
    func cleanSeriesRecoversSlope() throws {
        let series = samples(count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))

        #expect(abs(fit.percentPerHour - 10) < 0.01)
        #expect(abs(fit.interceptPercent - 10) < 0.01)
        #expect(fit.sampleCount == 9)
        #expect(abs(fit.spanHours - 40.0 / 60) < 1e-9)
        #expect(fit.standardErrorOfSlope < 1e-9)

        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 30, resetsAt: Self.now.addingTimeInterval(2 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        #expect(abs(projection.percentPerHour - 10) < 0.01)
        #expect(projection.currentPercent == 30)
        // 30% now, 10 points/hour, 2 hours of window left.
        let projected = try #require(projection.projectedAtReset)
        #expect(abs(projected - 50) < 0.05)
        // A perfect fit still reports a band — of zero width.
        let band = try #require(projection.projectedBand)
        #expect(band < 0.01)
        // The cap is 7 hours out but the window resets in 2, so there is no cap to show.
        #expect(projection.timeToCap == nil)
        #expect(projection.willCapEarly == false)
    }

    // MARK: - Degenerate regressions

    @Test("Degenerate series yield no fit rather than a NaN slope or standard error")
    func degenerateSeriesYieldNoFit() throws {
        // Five polls stamped at the same instant: zero variance in x, so the slope is
        // undefined and `sumXX` is the divisor that would blow up.
        let simultaneous = (0..<5).map { _ in
            Sample(
                t: Self.now, fiveHourPct: 10, fiveHourResetsAt: nil,
                sevenDayPct: nil, sevenDayResetsAt: nil)
        }
        #expect(ProjectionEngine.fit(simultaneous, kind: .fiveHour, now: Self.now) == nil)

        // Exactly `minimumSamples` points is the smallest n with any degrees of freedom
        // left (n − 2 == 2), so it is where a residual-variance formula divides by the
        // smallest number. The standard error must come back finite.
        let minimal = samples(count: ProjectionEngine.minimumSamples) { 10 + Double($0) * 2 }
        let fit = try #require(ProjectionEngine.fit(minimal, kind: .fiveHour, now: Self.now))
        #expect(fit.sampleCount == 4)
        #expect(abs(fit.percentPerHour - 24) < 1e-9)
        #expect(fit.standardErrorOfSlope.isNaN == false)
        #expect(fit.standardErrorOfSlope == 0)
    }

    // MARK: - Rolling window: a decline is not a reset

    @Test("A gently declining rolling 5-hour window fits a negative rate, not a segment break")
    func rollingDeclineIsNotAReset() throws {
        // 17% → 2% across 40 minutes, the shape observed on the real account as usage aged out.
        let series = samples(count: 9) { 42 - Double($0) * 1.875 }

        #expect(ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now).count == 9)

        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        #expect(fit.percentPerHour < 0)
        #expect(abs(fit.percentPerHour + 22.5) < 0.01)

        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 2, resetsAt: Self.now.addingTimeInterval(2 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        #expect(projection.sampleCount == 9)
        #expect(projection.timeToCap == nil)
        #expect(projection.willCapEarly == false)
        // Clamped at the display floor rather than shown as −43%.
        #expect(projection.projectedAtReset == 0)
    }

    @Test("Consecutive 19-point declines stay one segment and keep a steeply negative rate")
    func nearThresholdDeclineIsOneSegment() throws {
        // Every step falls by exactly 19 points — one shy of `resetDropThreshold` — so a
        // total collapse of 76 points must still read as one rolling window ageing out.
        // This is the assertion that breaks if anyone re-introduces "a drop means a reset"
        // or clamps the slope at zero.
        let percents = [76.0, 57, 38, 19, 0]
        let series = samples(count: percents.count) { percents[$0] }

        #expect(ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now).count == 5)

        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        #expect(abs(fit.percentPerHour + 228) < 0.01)
        #expect(abs(fit.spanHours - 20.0 / 60) < 1e-9)

        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 0, resetsAt: Self.now.addingTimeInterval(3 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        #expect(projection.sampleCount == 5)
        #expect(projection.timeToCap == nil)
        #expect(projection.projectedAtReset == 0)
    }

    @Test("A forward-drifting reset time is not itself a segment break")
    func driftingResetTimeIsNotASegmentBreak() throws {
        // The real 5-hour window pushes `resets_at` forward on every poll while utilization
        // ages out. Segmentation must key on the percentage drop alone — a moving reset time
        // is the normal state of a rolling window, not evidence that the window reset.
        let series = (0..<9).map { index -> Sample in
            let t = Self.now.addingTimeInterval(-Double(8 - index) * 5 * 60)
            return Sample(
                t: t, fiveHourPct: 42 - Double(index) * 1.875,
                fiveHourResetsAt: t.addingTimeInterval(5 * 3600),
                sevenDayPct: nil, sevenDayResetsAt: nil)
        }
        let firstReset = try #require(series.first?.resetsAt(for: .fiveHour))
        let lastReset = try #require(series.last?.resetsAt(for: .fiveHour))
        #expect(lastReset > firstReset)

        #expect(ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now).count == 9)
        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        #expect(abs(fit.percentPerHour + 22.5) < 0.01)
    }

    @Test("A 40-point cliff splits the series")
    func cliffSplitsSeries() throws {
        let percents = [50.0, 55, 60, 20, 22, 24, 26, 28, 30]
        let series = samples(count: percents.count) { percents[$0] }

        let usable = ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now)
        #expect(usable.count == 6)
        #expect(usable.first?.fiveHourPct == 20)
        #expect(usable.last?.fiveHourPct == 30)

        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        #expect(fit.sampleCount == 6)
        #expect(fit.percentPerHour > 0)
    }

    @Test("The reset threshold is inclusive: 20 points splits, 19.9 does not")
    func resetThresholdBoundary() {
        let exactly = [60.0, 40, 42, 44, 46, 48, 50, 52, 54]
        let under = [60.0, 40.1, 42, 44, 46, 48, 50, 52, 54]

        #expect(
            ProjectionEngine.usableSamples(
                samples(count: exactly.count) { exactly[$0] }, kind: .fiveHour, now: Self.now
            ).count == 8)
        #expect(
            ProjectionEngine.usableSamples(
                samples(count: under.count) { under[$0] }, kind: .fiveHour, now: Self.now
            ).count == 9)
    }

    @Test("Samples for another window, or from the future, are not usable")
    func usableSamplesFiltersKindAndFuture() {
        let weekly = samples(kind: .sevenDay, count: 9) { 10 + Double($0) }
        #expect(ProjectionEngine.usableSamples(weekly, kind: .fiveHour, now: Self.now).isEmpty)
        #expect(ProjectionEngine.usableSamples(weekly, kind: .sevenDay, now: Self.now).count == 9)

        let future = Sample(
            t: Self.now.addingTimeInterval(10 * 60), fiveHourPct: 99, fiveHourResetsAt: nil,
            sevenDayPct: nil, sevenDayResetsAt: nil)
        let series = samples(count: 9) { 10 + Double($0) } + [future]
        #expect(ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now).count == 9)
    }

    @Test("Samples older than the trailing window are dropped")
    func trailingWindowExcludesStaleSamples() {
        let stale = Sample(
            t: Self.now.addingTimeInterval(-3 * 3600), fiveHourPct: 90, fiveHourResetsAt: nil,
            sevenDayPct: nil, sevenDayResetsAt: nil)
        let series = [stale] + samples(count: 9) { 10 + Double($0) }
        let usable = ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now)
        #expect(usable.count == 9)
        #expect(usable.first?.fiveHourPct == 10)
    }

    // MARK: - Fallback to the estimated basis

    @Test("Below the sample minimum, the projection falls back to a token-velocity estimate")
    func belowMinimumSamplesFallsBack() throws {
        let series = samples(count: 3) { 18 + Double($0) }
        #expect(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now) == nil)

        let events = [
            event("old", at: Self.now.addingTimeInterval(-3 * 3600), output: 10_000),
            event("recent", at: Self.now.addingTimeInterval(-20 * 60), output: 10_000),
        ]
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 20, resetsAt: Self.now.addingTimeInterval(3 * 3600))),
                samples: series, events: events, now: Self.now))

        #expect(projection.basis == .estimated)
        #expect(projection.sampleCount == 3)
        // Half the window's weighted spend landed in the trailing 45 minutes, so
        // 20% × 0.5 accrued over 0.75h → 13.33 points/hour.
        #expect(abs(projection.percentPerHour - 40.0 / 3) < 1e-6)
        #expect(projection.projectedBand == nil)
    }

    @Test("Four samples inside a three-minute span are still below the span minimum")
    func shortSpanFallsBack() throws {
        let series = samples(stepMinutes: 1, count: 4) { 18 + Double($0) }
        #expect(series.count >= ProjectionEngine.minimumSamples)
        #expect(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now) == nil)

        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(fiveHour: LimitWindow(utilization: 21, resetsAt: nil)),
                samples: series, events: [], now: Self.now))
        #expect(projection.basis == .estimated)
        // No events and no reset time: nothing to project, and nothing invented.
        #expect(projection.percentPerHour == 0)
        #expect(projection.projectedAtReset == nil)
        #expect(projection.timeToCap == nil)
    }

    @Test("The estimated rate is zero without usable events")
    func estimatedRateWithoutEvents() {
        #expect(
            ProjectionEngine.estimatedRate(
                events: [], kind: .fiveHour, currentPercent: 30, now: Self.now) == 0)

        // Spend inside the window but nothing inside the trailing window: not burning now.
        let idle = [event("old", at: Self.now.addingTimeInterval(-2 * 3600), output: 10_000)]
        #expect(
            ProjectionEngine.estimatedRate(
                events: idle, kind: .fiveHour, currentPercent: 30, now: Self.now) == 0)

        // Nothing consumed yet, so there is no calibration to anchor the rate to.
        let busy = [event("recent", at: Self.now.addingTimeInterval(-5 * 60), output: 10_000)]
        #expect(
            ProjectionEngine.estimatedRate(
                events: busy, kind: .fiveHour, currentPercent: 0, now: Self.now) == 0)
    }

    @Test("`<synthetic>` rows do not contribute to the estimated rate")
    func syntheticExcludedFromEstimate() {
        let synthetic = [
            event("s1", at: Self.now.addingTimeInterval(-2 * 3600), output: 500_000,
                  model: "<synthetic>"),
            event("s2", at: Self.now.addingTimeInterval(-10 * 60), output: 500_000,
                  model: "<synthetic>"),
        ]
        #expect(
            ProjectionEngine.estimatedRate(
                events: synthetic, kind: .fiveHour, currentPercent: 30, now: Self.now) == 0)

        let mixed =
            synthetic + [
                event("old", at: Self.now.addingTimeInterval(-3 * 3600), output: 10_000),
                event("recent", at: Self.now.addingTimeInterval(-20 * 60), output: 10_000),
            ]
        let rate = ProjectionEngine.estimatedRate(
            events: mixed, kind: .fiveHour, currentPercent: 20, now: Self.now)
        #expect(abs(rate - 40.0 / 3) < 1e-6)
    }

    // MARK: - Cap crossing

    @Test("willCapEarly is true when the fit crosses 100% before the reset")
    func capsBeforeReset() throws {
        // 10 points/hour from 50% needs 5 hours to reach 100%; the window resets in 6.
        let series = samples(kind: .sevenDay, count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .sevenDay,
                snapshot: snapshot(
                    sevenDay: LimitWindow(
                        utilization: 50, resetsAt: Self.now.addingTimeInterval(6 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        let cap = try #require(projection.timeToCap)
        #expect(abs(cap.timeIntervalSince(Self.now) - 5 * 3600) < 20)
        #expect(projection.willCapEarly)
    }

    @Test("willCapEarly is false when the crossing falls beyond the reset")
    func capsAfterReset() throws {
        let series = samples(count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 50, resetsAt: Self.now.addingTimeInterval(2 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.timeToCap == nil)
        #expect(projection.willCapEarly == false)
        let projected = try #require(projection.projectedAtReset)
        #expect(abs(projected - 70) < 0.05)
    }

    @Test("The displayed projection is clamped to 200%, the cap time is not")
    func projectionClampedForDisplay() throws {
        let series = samples(count: 9) { 10 + 100 * (Double($0) * 5 / 60) }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 80, resetsAt: Self.now.addingTimeInterval(4 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.projectedAtReset == 200)
        let cap = try #require(projection.timeToCap)
        #expect(abs(cap.timeIntervalSince(Self.now) - 12 * 60) < 30)
        #expect(projection.willCapEarly)
    }

    // MARK: - Band

    @Test("A noisy series hides the confidence band")
    func noisySeriesHidesBand() throws {
        // Swings of 18 points stay under the reset threshold, so the series is not split —
        // it is simply a terrible fit.
        let series = samples(count: 9) { $0 % 2 == 0 ? 50 : 68 }
        #expect(ProjectionEngine.usableSamples(series, kind: .fiveHour, now: Self.now).count == 9)

        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        #expect(fit.standardErrorOfSlope > 1)

        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 40, resetsAt: Self.now.addingTimeInterval(4 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        #expect(projection.projectedBand == nil)
        #expect(projection.projectedAtReset != nil)
    }

    @Test("The band survives up to maximumBandToShow and disappears once past it")
    func bandVisibilityTracksTheMaximum() throws {
        // The same badly-fitting series as above. Its band widens linearly with the
        // horizon, so the identical fit lands either side of the 40-point ceiling
        // purely by moving `resetsAt`.
        let series = samples(count: 9) { $0 % 2 == 0 ? 50 : 68 }
        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))
        let pointsPerHourOfHorizon = 1.96 * fit.standardErrorOfSlope
        #expect(pointsPerHourOfHorizon < ProjectionEngine.maximumBandToShow)
        #expect(pointsPerHourOfHorizon * 2 > ProjectionEngine.maximumBandToShow)

        func band(hoursUntilReset: Double) -> Double? {
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 40,
                        resetsAt: Self.now.addingTimeInterval(hoursUntilReset * 3600))),
                samples: series, events: [], now: Self.now
            )?.projectedBand
        }

        let shown = try #require(band(hoursUntilReset: 1))
        #expect(abs(shown - pointsPerHourOfHorizon) < 1e-9)
        #expect(band(hoursUntilReset: 2) == nil)
    }

    // MARK: - Absent windows

    @Test("A window missing from the snapshot projects nil")
    func missingWindowProjectsNil() {
        let sparse = snapshot(sevenDay: LimitWindow(utilization: 93.5, resetsAt: nil))
        #expect(
            ProjectionEngine.project(
                kind: .fiveHour, snapshot: sparse, samples: [], events: [], now: Self.now) == nil)
        #expect(
            ProjectionEngine.project(
                kind: .sevenDay, snapshot: sparse, samples: [], events: [], now: Self.now) != nil)
    }
}
