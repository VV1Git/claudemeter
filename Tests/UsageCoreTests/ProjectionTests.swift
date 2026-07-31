import Foundation
import Testing

@testable import UsageCore

/// `ProjectionEngine` is pure arithmetic over samples and events the caller supplies: no
/// filesystem, network, or Keychain access, so no `Paths` override is needed here.
struct ProjectionTests {

    // MARK: - Fixtures

    private static let now = ISO8601.date(from: "2026-01-15T12:00:00Z")!

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
        // A geometrically perfect series still has a standard error, because the API reports
        // whole percentage points and a run of integers that happens to lie on a line is not
        // evidence that the underlying value did. The residual scale floors at the quantum.
        #expect(fit.residualSigma == ProjectionEngine.quantizationSigma)
        #expect(
            abs(
                fit.standardErrorOfSlope
                    - ProjectionEngine.quantizationSigma / fit.sumSquaredDeviations.squareRoot()
            ) < 1e-12)

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
        // A perfect fit reports a band of real width, not of zero width. Zero would claim the
        // next two hours are known to the percentage point on the strength of nine integers.
        let band = try #require(projection.projectedBand)
        #expect(band > 1)
        #expect(abs(band - ProjectionEngine.halfWidth(fit: fit, hours: 2)) < 1e-9)
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
        // Finite and strictly positive: n − 2 == 2 leaves the residual variance divided by the
        // smallest number the formula ever sees, and a collinear fixture drives it to zero
        // before the quantization floor picks it up.
        #expect(fit.standardErrorOfSlope > 0)
        #expect(fit.standardErrorOfSlope.isFinite)
    }

    // MARK: - Rolling window: a decline is not a reset

    @Test("A gently declining rolling 5-hour window fits a negative rate, not a segment break")
    func rollingDeclineIsNotAReset() throws {
        // 42% → 27% across 40 minutes: the shape a rolling window takes as usage ages out.
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
                        utilization: 27, resetsAt: Self.now.addingTimeInterval(2 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        #expect(projection.sampleCount == 9)
        #expect(projection.timeToCap == nil)
        #expect(projection.willCapEarly == false)
        // Clamped at the display floor rather than shown as a negative percentage.
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
        // A rolling 5-hour window pushes `resets_at` forward on every poll while utilization
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
        let series = samples(count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 50, resetsAt: Self.now.addingTimeInterval(6 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        let cap = try #require(projection.timeToCap)
        #expect(abs(cap.timeIntervalSince(Self.now) - 5 * 3600) < 20)
        #expect(projection.willCapEarly)
    }

    // MARK: - Weekly window: paced, never regressed

    @Test("The weekly window is paced from its own consumption, not fitted from recent polls")
    func weeklyIsPacedNotFitted() throws {
        // A burst: 45 minutes of polls climbing at 10 points/hour. Regressed and carried to a
        // reset three days out, that is a projection of several hundred percent. The window
        // itself says something completely different — 50% consumed with four days gone — and
        // the window is the one that knows.
        let series = samples(kind: .sevenDay, count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        let projection = try #require(
            ProjectionEngine.project(
                kind: .sevenDay,
                snapshot: snapshot(sevenDay: LimitWindow(utilization: 50, resetsAt: resetsAt)),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .paced)
        // Four of the seven days are gone and half the budget with them: 12.5 points a day.
        #expect(abs(projection.percentPerHour * 24 - 12.5) < 0.01)
        // Three days left at that pace lands at 87.5%, not at the regression's several hundred.
        let projected = try #require(projection.projectedAtReset)
        #expect(abs(projected - 87.5) < 0.1)
        #expect(projected < 100)
    }

    @Test("A weekly window barely open is not paced from a single quantization step")
    func weeklyTooYoungToPace() throws {
        // Ten minutes in, one percentage point showing. Dividing by the elapsed time turns
        // the rounding step itself into 6 points an hour, which reaches 1000% by the reset.
        let resetsAt = Self.now.addingTimeInterval(7 * 24 * 3600 - 600)
        let projection = try #require(
            ProjectionEngine.project(
                kind: .sevenDay,
                snapshot: snapshot(sevenDay: LimitWindow(utilization: 1, resetsAt: resetsAt)),
                samples: [], events: [], now: Self.now))

        #expect(projection.basis != .paced)
        // Falls through to the regression path, which has no samples and no events, so it
        // reports no movement at all rather than the 1000% pacing would have produced.
        #expect(projection.percentPerHour == 0)
        let projected = try #require(projection.projectedAtReset)
        #expect(abs(projected - 1) < 1e-9)
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

    @Test("A noisy series states a wide band rather than hiding the forecast")
    func noisySeriesStatesAWideBand() throws {
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
        // This used to assert that both went away. Deleting a forecast because its interval is
        // wide loses the forecast and the warning together, and it was doing so on every
        // reading this account produced. A terrible fit now reports its centre with an interval
        // wide enough to say not to lean on it, which is what a `±` is for.
        let band = try #require(projection.projectedBand)
        #expect(!ProjectionEngine.bandIsInformative(band, currentPercent: 40))
        #expect(projection.projectedAtReset != nil)
        // The rate itself is still measured and still worth showing — it says what is
        // happening now, which is a claim about the past rather than about the reset.
        #expect(projection.percentPerHour.isFinite)
    }

    @Test("The band widens with the horizon, and every fit keeps its forecast")
    func bandWidensWithTheHorizon() throws {
        // The same badly-fitting series as above. Its band widens with the horizon, so the
        // identical fit lands either side of the ceiling purely by moving `resetsAt`.
        let series = samples(count: 9) { $0 % 2 == 0 ? 50 : 68 }
        let fit = try #require(ProjectionEngine.fit(series, kind: .fiveHour, now: Self.now))

        func projection(hoursUntilReset: Double) -> Projection? {
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 40,
                        resetsAt: Self.now.addingTimeInterval(hoursUntilReset * 3600))),
                samples: series, events: [], now: Self.now)
        }

        // The ceiling scales with the headroom, not with a flat 40 points: at 40% used there
        // are 60 points to play for, so half of that is what a band has to beat.
        let ceiling = (100 - 40.0) * 0.5
        #expect(ProjectionEngine.bandIsInformative(ceiling - 1, currentPercent: 40))
        #expect(!ProjectionEngine.bandIsInformative(ceiling + 1, currentPercent: 40))

        // The band widens with the horizon, monotonically, so the same fit crosses the
        // ceiling purely by moving the reset further out.
        #expect(
            ProjectionEngine.halfWidth(fit: fit, hours: 1)
                < ProjectionEngine.halfWidth(fit: fit, hours: 4))

        // This fit is bad enough that it is over the ceiling at any horizon: alternating
        // 50/68 is 10 points of residual scatter, and the interval covers the anchor's own
        // noise twice over before the slope contributes anything.
        #expect(ProjectionEngine.halfWidth(fit: fit, hours: 0.25) > ceiling)
        let noisy = try #require(projection(hoursUntilReset: 4))
        // Both are kept. The ceiling still says the band is too wide to act on; it no longer
        // decides whether the reader is told anything at all.
        let noisyBand = try #require(noisy.projectedBand)
        #expect(!ProjectionEngine.bandIsInformative(noisyBand, currentPercent: 40))
        #expect(noisy.projectedAtReset != nil)

        // A clean fit at the same horizon and the same utilization clears the ceiling, so what
        // is being tested is the quality of the evidence and not the shape of the test.
        let cleanSeries = samples(count: 9) { 10 + 10 * (Double($0) * 5 / 60) }
        let clean = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 40, resetsAt: Self.now.addingTimeInterval(4 * 3600))),
                samples: cleanSeries, events: [], now: Self.now))
        let shown = try #require(clean.projectedBand)
        #expect(ProjectionEngine.bandIsInformative(shown, currentPercent: 40))
        #expect(clean.projectedAtReset != nil)
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

    // MARK: - The weekly forecast survives a wide interval

    /// Fourteen days of wildly uneven usage, which is what a real account looks like: one
    /// enormous day among a fortnight of quiet ones. This is the shape that used to blank the
    /// weekly row entirely.
    private func lumpyFortnight(now: Date = ProjectionTests.now) -> [UsageEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var events: [UsageEvent] = []
        for offset in 1...14 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let output = offset == 1 ? 4_000_000 : (offset % 4 == 0 ? 120_000 : 0)
            guard output > 0 else { continue }
            events.append(
                event("day-\(offset)", at: day.addingTimeInterval(43_200), output: output))
        }
        return events
    }

    @Test("A weekly forecast too uncertain to put a ± on is still shown, as an interval")
    func weeklyWideIntervalIsShownNotWithdrawn() throws {
        // The reported bug. At this account's real spread the half-width lands well past
        // `bandIsInformative`'s ceiling, and the old code deleted the projection along with the
        // band — so the row printed a pace and nothing about where the week was heading.
        let resetsAt = Self.now.addingTimeInterval(2.24 * 24 * 3600)
        let projection = try #require(
            ProjectionEngine.project(
                kind: .sevenDay,
                snapshot: snapshot(sevenDay: LimitWindow(utilization: 35, resetsAt: resetsAt)),
                samples: [], events: lumpyFortnight(), now: Self.now))

        #expect(projection.basis == .paced)
        let projected = try #require(projection.projectedAtReset)
        let band = try #require(projection.projectedBand)
        // Wide enough that the old gate would have withdrawn both, which is the whole point.
        #expect(!ProjectionEngine.bandIsInformative(band, currentPercent: 35))
        // 35% consumed over 114.2 elapsed hours is 0.306 points an hour; 53.8 hours left of
        // the window carries that to 51.5%, which is the number the row had been withholding.
        #expect(abs(projected - 51.5) < 0.5)
    }

    @Test("A paced weekly window always carries an interval, even with no history to measure")
    func pacedWeeklyAlwaysHasAnInterval() throws {
        // No events at all, so `dailyVariation` has nothing to say. It must widen the interval
        // to the engine's worst case rather than leave a bare number, which is exactly the
        // interval-free forecast the suppression rule exists to prevent.
        let resetsAt = Self.now.addingTimeInterval(3 * 24 * 3600)
        let projection = try #require(
            ProjectionEngine.project(
                kind: .sevenDay,
                snapshot: snapshot(sevenDay: LimitWindow(utilization: 50, resetsAt: resetsAt)),
                samples: [], events: [], now: Self.now))

        #expect(projection.basis == .paced)
        #expect(projection.projectedAtReset != nil)
        let band = try #require(projection.projectedBand)
        #expect(band > 0)
    }

    @Test("The 5-hour window states its interval too, however wide the fit makes it")
    func fiveHourAlsoStatesItsInterval() throws {
        // Both windows answer the same way now. The 5-hour one reaches this through the fitted
        // path, whose horizon is at most five hours — the 171% that suppression was written
        // against came from regressing the *weekly* window across three days, and that window
        // is paced now and never reaches here.
        let series = samples(count: 9) { $0 % 2 == 0 ? 30 : 46 }
        let projection = try #require(
            ProjectionEngine.project(
                kind: .fiveHour,
                snapshot: snapshot(
                    fiveHour: LimitWindow(
                        utilization: 38, resetsAt: Self.now.addingTimeInterval(4 * 3600))),
                samples: series, events: [], now: Self.now))

        #expect(projection.basis == .measured)
        let band = try #require(projection.projectedBand)
        #expect(band > 0)
        #expect(projection.projectedAtReset != nil)
        // Not floored, unlike the weekly window: a rolling window really can shed usage.
        #expect(projection.projectedLow == 0 || projection.projectedLow! < 38)
    }

    // MARK: - Interval endpoints

    @Test("The weekly interval cannot claim the window will un-consume usage")
    func weeklyIntervalIsFlooredAtTheCurrentReading() throws {
        // A fixed window only climbs within a cycle, so a lower end under the current reading
        // is not uncertainty, it is an impossible claim. Unfloored this band reaches -20.
        let projection = Projection(
            kind: .sevenDay, basis: .paced, percentPerHour: 0.3, currentPercent: 35,
            timeToCap: nil, projectedAtReset: 50, projectedBand: 70,
            resetsAt: Self.now.addingTimeInterval(2 * 24 * 3600), sampleCount: 0)

        #expect(projection.projectedLow == 35)
        #expect(projection.projectedHigh == 120)
    }

    @Test("The 5-hour interval is not floored, because that window really does shed usage")
    func fiveHourIntervalIsNotFloored() throws {
        let projection = Projection(
            kind: .fiveHour, basis: .measured, percentPerHour: 2, currentPercent: 35,
            timeToCap: nil, projectedAtReset: 50, projectedBand: 70,
            resetsAt: Self.now.addingTimeInterval(3 * 3600), sampleCount: 8)

        #expect(projection.projectedLow == 0)
    }

    @Test("Interval endpoints never invert and never exceed the display ceiling")
    func intervalEndpointsStayTotal() throws {
        let enormous = Projection(
            kind: .sevenDay, basis: .paced, percentPerHour: 5, currentPercent: 3,
            timeToCap: nil, projectedAtReset: 40, projectedBand: 1_004,
            resetsAt: Self.now.addingTimeInterval(6 * 24 * 3600), sampleCount: 0)

        let low = try #require(enormous.projectedLow)
        let high = try #require(enormous.projectedHigh)
        #expect(low <= 40)
        #expect(high == ProjectionEngine.displayCeiling)

        // No band, no interval — the endpoints are not invented from the centre alone.
        let bandless = Projection(
            kind: .sevenDay, basis: .paced, percentPerHour: 1, currentPercent: 10,
            timeToCap: nil, projectedAtReset: 30, projectedBand: nil,
            resetsAt: nil, sampleCount: 0)
        #expect(bandless.projectedLow == nil)
        #expect(bandless.projectedHigh == nil)
    }

    // MARK: - The chart spans the period, not a lookback

    @Test("An open window's chart period runs from when it opened to when it resets")
    func chartPeriodSpansTheOpenWindow() {
        let resetsAt = Self.now.addingTimeInterval(2 * 3600)
        let period = WindowKind.fiveHour.chartPeriod(resetsAt: resetsAt, now: Self.now)

        #expect(period.end == resetsAt)
        #expect(abs(period.start.timeIntervalSince(resetsAt) + 5 * 3600) < 1e-9)
        // The period contains `now`, so the boundary between observed and forecast is on-chart.
        #expect(period.start <= Self.now && Self.now <= period.end)
    }

    @Test("A window that turned over before the next poll charts the period that just opened")
    func chartPeriodFollowsATurnover() {
        // Up to five minutes under backoff, several times a day: the reset instant is in the
        // past because nothing has polled since it passed.
        let resetsAt = Self.now.addingTimeInterval(-120)
        let period = WindowKind.fiveHour.chartPeriod(resetsAt: resetsAt, now: Self.now)

        #expect(period.start == resetsAt)
        #expect(abs(period.end.timeIntervalSince(resetsAt) - 5 * 3600) < 1e-9)
    }

    @Test("An absent or impossible reset instant falls back to the trailing period")
    func chartPeriodFallsBackWithoutAReset() {
        for resetsAt in [nil, Self.now.addingTimeInterval(9 * 3600)] as [Date?] {
            let period = WindowKind.fiveHour.chartPeriod(resetsAt: resetsAt, now: Self.now)
            #expect(period.end == Self.now)
            #expect(abs(period.start.timeIntervalSince(Self.now) + 5 * 3600) < 1e-9)
        }
        // Every branch stays total, so `start...end` cannot trap.
        for kind in [WindowKind.fiveHour, .sevenDay] {
            let period = kind.chartPeriod(resetsAt: nil, now: Self.now)
            #expect(period.start < period.end)
        }
    }

    @Test("Chart samples stop at the period's edges and cut at a turnover")
    func chartSamplesRespectThePeriod() throws {
        let resetsAt = Self.now.addingTimeInterval(3600)
        let period = WindowKind.fiveHour.chartPeriod(resetsAt: resetsAt, now: Self.now)
        let previousReset = resetsAt.addingTimeInterval(-5 * 3600)

        // Two readings from the block that closed at `previousReset`, then three from this one.
        // The 15 → 1 step is only 14 points, under `resetDropThreshold`, so the chart's old
        // percentage-drop rule missed it and drew a cliff straight through a real turnover.
        let series = [
            Sample(
                t: previousReset.addingTimeInterval(-600), fiveHourPct: 12,
                fiveHourResetsAt: previousReset, sevenDayPct: nil, sevenDayResetsAt: nil),
            Sample(
                t: previousReset.addingTimeInterval(-60), fiveHourPct: 15,
                fiveHourResetsAt: previousReset, sevenDayPct: nil, sevenDayResetsAt: nil),
            Sample(
                t: previousReset.addingTimeInterval(600), fiveHourPct: 1,
                fiveHourResetsAt: resetsAt, sevenDayPct: nil, sevenDayResetsAt: nil),
            Sample(
                t: Self.now.addingTimeInterval(-600), fiveHourPct: 6,
                fiveHourResetsAt: resetsAt, sevenDayPct: nil, sevenDayResetsAt: nil),
            // Beyond the period's end: a stale row from a future the chart does not draw.
            Sample(
                t: resetsAt.addingTimeInterval(60), fiveHourPct: 9,
                fiveHourResetsAt: resetsAt, sevenDayPct: nil, sevenDayResetsAt: nil),
        ]

        let kept = ProjectionEngine.chartSamples(series, kind: .fiveHour, period: period)
        #expect(kept.count == 2)
        #expect(kept.first?.fiveHourPct == 1)
        #expect(kept.last?.fiveHourPct == 6)
    }
}
