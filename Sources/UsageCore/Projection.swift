import Foundation

// MARK: - Burn rate fit

/// A least-squares fit of utilization against time over the trailing poll series.
///
/// Carried separately from `Projection` so the regression quality (`standardErrorOfSlope`,
/// `spanHours`) stays inspectable: the UI has to be able to tell a rate measured over
/// 40 minutes of steady polling from one scraped off four noisy points.
///
/// The terms behind the standard error are kept alongside it rather than collapsed into it.
/// A prediction interval at a horizon needs the residual scale, the spread of the fitted
/// x-values and the distance from their mean to the anchor — `standardErrorOfSlope` alone
/// has already thrown two of the three away.
public struct BurnRateFit: Sendable, Equatable {
    /// Slope in percentage points per hour. Negative is a legitimate result, not an
    /// error — the 5-hour window is rolling, so utilization falls whenever usage ages
    /// out faster than it accrues.
    public let percentPerHour: Double
    /// Fitted utilization at the *first* sample of the usable series, not at `now`. The
    /// series slides forward every poll, so this is the anchor the slope was measured
    /// from rather than a stable baseline.
    public let interceptPercent: Double
    /// Standard error of `percentPerHour`, in points per hour. Never zero — see
    /// `ProjectionEngine.quantizationSigma`.
    public let standardErrorOfSlope: Double
    public let sampleCount: Int
    public let spanHours: Double
    /// Residual standard deviation, floored at the reporting quantum.
    public let residualSigma: Double
    /// Σ(xᵢ − x̄)² over the fitted points, x in hours. The lever the slope was measured on.
    public let sumSquaredDeviations: Double
    /// Distance in hours from the mean fitted x to the last one — the offset between where
    /// the regression is centred and where the projection is anchored.
    public let lastPointOffset: Double

    public init(
        percentPerHour: Double, interceptPercent: Double, standardErrorOfSlope: Double,
        sampleCount: Int, spanHours: Double, residualSigma: Double = 0,
        sumSquaredDeviations: Double = 0, lastPointOffset: Double = 0
    ) {
        self.percentPerHour = percentPerHour
        self.interceptPercent = interceptPercent
        self.standardErrorOfSlope = standardErrorOfSlope
        self.sampleCount = sampleCount
        self.spanHours = spanHours
        self.residualSigma = residualSigma
        self.sumSquaredDeviations = sumSquaredDeviations
        self.lastPointOffset = lastPointOffset
    }
}

// MARK: - Projection engine

/// Turns the persisted poll series into a burn rate and a projection to the window reset.
///
/// The two windows are projected by different means, because they are different problems.
///
/// The 5-hour window is *rolling* and close: a 45-minute regression carried a few hours
/// forward is a six-to-one extrapolation, the residuals are what the interval is made of, and
/// a change of pace has to show up within a couple of polls. That is what `fit` is for.
///
/// The 7-day window is *fixed* — `resets_at` holds still for the whole cycle — and far away.
/// Regressing it is indefensible, and quantifiably so: exhausting the entire weekly budget in
/// exactly one week is 0.6 points per hour, which moves the reading by less than half a point
/// across a 45-minute fit. That is a sub-quantum signal, and multiplying it by a 168-hour
/// horizon produced projections over 100% on every informative fit of a real session that
/// finished the week at 23%. Fitting over a longer span does not rescue it; it makes the
/// extrapolation *more confident* while leaving it just as wrong, because what the regression
/// band measures is how straight the recent history was, not what somebody will do for the
/// next three days. So the weekly window is paced instead — see `pacedProjection`.
///
/// Everything here is pure: no filesystem, no network. The caller owns the samples and
/// the snapshot, which is what makes the reset-detection rules testable.
public enum ProjectionEngine {
    /// How far back to fit. Short enough that a change of pace shows up within a few
    /// polls, long enough to average out the granularity of the API's own percentages.
    public static let trailingWindow: TimeInterval = 45 * 60
    public static let minimumSamples = 4
    public static let minimumSpan: TimeInterval = 10 * 60
    /// Drop between consecutive polls, in percentage points, that counts as a reset when the
    /// window's own `resets_at` says nothing.
    public static let resetDropThreshold: Double = 20
    /// Floor for `bandIsInformative`, in points.
    public static let maximumBandToShow: Double = 40

    /// The API reports utilization as whole percentage points, so an observation carries a
    /// rounding error of up to half a point even when the underlying value is exact.
    public static let reportingQuantum: Double = 1

    /// Standard deviation of that rounding error: uniform over ±q/2 has sd q/√12.
    ///
    /// This is the floor on residual scatter, and it is the difference between an honest
    /// band and a false one. A run of identical integers — which is what a slow window
    /// reports for minutes at a time — fits a straight line with zero residual, and the
    /// textbook standard error of that fit is exactly zero. Reported unfloored, it claims
    /// the next several hours are known to the percentage point.
    public static let quantizationSigma: Double = reportingQuantum / (12.0).squareRoot()

    /// 95% two-sided normal quantile — the large-sample limit of `confidenceT(df:)`.
    private static let confidenceZ: Double = 1.959_964
    /// Ceiling for the *displayed* projection. `timeToCap` is left unclamped.
    private static let displayCeiling: Double = 200
    private static let syntheticModel = "<synthetic>"

    // MARK: Confidence quantile

    /// Two-sided 95% Student-t quantile for `df` degrees of freedom.
    ///
    /// A regression over four polls has two degrees of freedom, where the right multiplier is
    /// 4.30 and not 1.96 — the normal quantile reports a band 55% narrower than it is. Four
    /// polls is not a corner case either: the poll interval backs off to 15 minutes under rate
    /// limiting, which parks the fit at exactly four samples for as long as the backoff lasts.
    public static func confidenceT(df: Int) -> Double {
        guard df >= 1 else { return smallSampleT[0] }
        guard df <= smallSampleT.count else { return confidenceZ + 2.37 / Double(df) }
        return smallSampleT[df - 1]
    }

    /// `t(0.975, df)` for df = 1...30.
    private static let smallSampleT: [Double] = [
        12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646, 2.3060, 2.2622, 2.2281,
        2.2010, 2.1788, 2.1604, 2.1448, 2.1314, 2.1199, 2.1098, 2.1009, 2.0930, 2.0860,
        2.0796, 2.0739, 2.0687, 2.0639, 2.0595, 2.0555, 2.0518, 2.0484, 2.0452, 2.0423,
    ]

    /// Whether a band still separates "fine" from "you will run out".
    ///
    /// Relative to the headroom rather than absolute. Forty points of uncertainty on a window
    /// at 5% is noise; the same forty points on a window at 80% is the whole question. The
    /// floor keeps a nearly-full window from suppressing every band it produces.
    public static func bandIsInformative(_ halfWidth: Double, currentPercent: Double) -> Bool {
        guard halfWidth.isFinite, halfWidth >= 0 else { return false }
        return halfWidth <= max(10, min(maximumBandToShow, (100 - currentPercent) * 0.5))
    }

    // MARK: Series selection

    /// Trailing-window samples for `kind`, ascending, cut at the most recent reset boundary.
    ///
    /// Samples missing a percentage for `kind` are dropped rather than treated as zero —
    /// the API returns `null` windows routinely and a zero would read as a reset.
    public static func usableSamples(_ samples: [Sample], kind: WindowKind, now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-trailingWindow)
        let series = samples
            .filter { $0.t <= now && $0.t >= cutoff && $0.percent(for: kind) != nil }
            .sorted { $0.t < $1.t }
        guard series.count > 1 else { return series }

        var start = 0
        for i in 1..<series.count where isResetBoundary(series[i - 1], series[i], kind: kind) {
            start = i
        }
        return Array(series[start...])
    }

    /// A falling percentage is *not* a reset. The 5-hour window is rolling — utilization can
    /// slide a long way down purely by ageing out, with `resets_at` drifting forward the
    /// whole time.
    ///
    /// The window's own reset instant is the authority and is checked first: it holds still
    /// within a cycle and jumps by about a nominal duration when the window turns over, which
    /// identifies a reset regardless of how little was used. The percentage cliff is only the
    /// fallback for samples with no `resets_at`, and it is taken as *relative* as well as
    /// absolute — a week that peaked at 12% resets to 0 without ever dropping the 20 points
    /// the flat threshold demands, and would otherwise be fitted straight across its own reset.
    private static func isResetBoundary(_ previous: Sample, _ next: Sample, kind: WindowKind) -> Bool {
        if let before = previous.resetsAt(for: kind), let after = next.resetsAt(for: kind) {
            // A *jump*, not any movement. The 5-hour window's reset instant drifts forward
            // continuously as usage ages out — five minutes per five minutes of wall clock —
            // so treating every advance as a boundary would cut the series at every poll and
            // leave nothing to fit. Turning over moves it by about a whole window.
            if after.timeIntervalSince(before) > kind.nominalDuration / 2 { return true }
        }
        guard let before = previous.percent(for: kind), let after = next.percent(for: kind) else {
            return false
        }
        switch kind {
        case .fiveHour:
            // Rolling, so a decline is ordinary: utilization slides down whenever usage ages
            // out faster than it accrues, and a long steady fall is one segment, not many.
            // Only a cliff counts.
            return before - after >= resetDropThreshold
        case .sevenDay:
            // Fixed, so within a cycle utilization only ever climbs. Any genuine drop is the
            // window turning over — including a quiet week that peaked in single figures and
            // never fell the 20 points the rolling threshold waits for.
            return before - after >= reportingQuantum
        }
    }

    // MARK: Regression

    /// Least-squares fit in percentage points per hour. `nil` when the usable series is
    /// under `minimumSamples` points or spans less than `minimumSpan` — a rate fitted to
    /// two-minutes-worth of polls is noise dressed as a number.
    public static func fit(_ samples: [Sample], kind: WindowKind, now: Date) -> BurnRateFit? {
        let series = usableSamples(samples, kind: kind, now: now)
        guard series.count >= minimumSamples, let first = series.first, let last = series.last else {
            return nil
        }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= minimumSpan else { return nil }

        let points: [(x: Double, y: Double)] = series.compactMap { sample in
            guard let percent = sample.percent(for: kind) else { return nil }
            return (sample.t.timeIntervalSince(first.t) / 3600, percent)
        }
        guard points.count >= minimumSamples else { return nil }

        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var sumXX = 0.0
        var sumXY = 0.0
        for point in points {
            let dx = point.x - meanX
            sumXX += dx * dx
            sumXY += dx * (point.y - meanY)
        }
        guard sumXX > 0 else { return nil }

        let slope = sumXY / sumXX
        let intercept = meanY - slope * meanX
        var residualSumSquares = 0.0
        for point in points {
            let residual = point.y - (intercept + slope * point.x)
            residualSumSquares += residual * residual
        }
        let degreesOfFreedom = count - 2
        let variance = degreesOfFreedom > 0 ? max(0, residualSumSquares / degreesOfFreedom) : 0
        let residualSigma = max(variance.squareRoot(), quantizationSigma)
        let standardError = residualSigma / sumXX.squareRoot()

        return BurnRateFit(
            percentPerHour: slope,
            interceptPercent: intercept,
            standardErrorOfSlope: standardError,
            sampleCount: points.count,
            spanHours: span / 3600,
            residualSigma: residualSigma,
            sumSquaredDeviations: sumXX,
            lastPointOffset: (points.last?.x ?? 0) - meanX
        )
    }

    /// Half-width of the 95% prediction interval `hours` past the last fitted sample.
    ///
    /// The projection is `yₙ + b·h`, anchored on the observed current reading rather than on
    /// the fitted line, so the error is `(β − b)·h + ε₀ − εₙ`. That anchor is itself a noisy,
    /// quantized observation, and it is one of the points the slope was fitted to, so it is
    /// correlated with `b`. Working the variance through:
    ///
    ///     Var = σ²·[ 2 + (h² + 2·h·d)/Sxx ],  d = xₙ − x̄
    ///
    /// The two extra terms are not a rounding detail. `z·SE(b)·h` — the slope term alone with
    /// a normal quantile — came out a median 1.7× too narrow across a real session's fits.
    public static func halfWidth(fit: BurnRateFit, hours: Double) -> Double {
        guard hours.isFinite, fit.sampleCount > 2, fit.sumSquaredDeviations > 0,
            fit.residualSigma.isFinite
        else { return .infinity }
        let offset = fit.lastPointOffset
        let scale = 2 + (hours * hours + 2 * hours * offset) / fit.sumSquaredDeviations
        guard scale > 0 else { return .infinity }
        return confidenceT(df: fit.sampleCount - 2) * fit.residualSigma * scale.squareRoot()
    }

    // MARK: Fallback rate

    /// Burn rate inferred from transcript token velocity when the poll series is too thin
    /// to fit — typically the first few minutes after launch.
    ///
    /// Calibration: the weighted tokens spent inside the current window account for
    /// `currentPercent`, which gives points-per-token without any knowledge of the account's
    /// actual limits. That factor is then applied to the most recent `trailingWindow` of
    /// token spend. Returns points per hour; 0 when there is nothing to go on, which reads
    /// as "not burning" rather than as a guess.
    ///
    /// `resetsAt` is what makes the window boundary right for the fixed weekly window, whose
    /// start is `resetsAt − 7d` and not `now − 7d`. The two differ by however long is left on
    /// the clock, and charging the current window with spend from before it opened deflates
    /// the calibration by that ratio — most of a factor of two, mid-week.
    ///
    /// Only local Claude Code transcripts are visible here, so usage from claude.ai, the
    /// desktop app or another machine is attributed to the tokens this machine can see and
    /// inflates the rate accordingly.
    public static func estimatedRate(
        events: [UsageEvent], kind: WindowKind, currentPercent: Double, now: Date,
        resetsAt: Date? = nil
    ) -> Double {
        guard currentPercent > 0 else { return 0 }
        // Only the weekly window has a start worth deriving from its reset. The 5-hour window
        // is rolling: its `resets_at` drifts with the usage ageing out, so `resetsAt − 5h` is
        // not where it opened, and `now − 5h` is exactly the span still counting against it.
        let windowStart: Date
        if kind == .sevenDay, let resetsAt {
            windowStart = resetsAt.addingTimeInterval(-kind.nominalDuration)
        } else {
            windowStart = now.addingTimeInterval(-kind.nominalDuration)
        }
        let inWindow = events.filter {
            $0.timestamp > windowStart && $0.timestamp <= now && $0.model != syntheticModel
        }
        let windowWeight = inWindow.reduce(0.0) { $0 + weight($1.tokens) }
        guard windowWeight > 0 else { return 0 }

        let recentStart = now.addingTimeInterval(-trailingWindow)
        let recentWeight = inWindow
            .filter { $0.timestamp > recentStart }
            .reduce(0.0) { $0 + weight($1.tokens) }
        guard recentWeight > 0 else { return 0 }

        let pointsPerUnit = currentPercent / windowWeight
        return pointsPerUnit * recentWeight / (trailingWindow / 3600)
    }

    /// Rate limits track something closer to spend than to raw token count, so tokens are
    /// weighted by their relative API price: output is the expensive side, cache reads a
    /// tenth of fresh input, cache writes a quarter more. The absolute scale cancels out in
    /// the calibration against `currentPercent`, so only the *ratios* matter here — which is
    /// why this deliberately does not depend on per-model rates.
    ///
    /// The multiples are `ModelRate`'s rather than literals, so a pricing change cannot leave
    /// the burn rate weighting tokens the old way. What this does not model is the difference
    /// *between* models: an Opus token and a Sonnet token weigh the same here while consuming
    /// the limit at very different rates, so a session that switches model mid-window
    /// miscalibrates until the poll series is long enough to fit.
    private static func weight(_ tokens: TokenCounts) -> Double {
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

    // MARK: Daily variation

    /// Trailing complete days of local usage used to estimate how much a day varies.
    public static let variationDays = 14
    /// Fewer complete days than this and there is no spread worth quoting.
    public static let minimumVariationDays = 4

    /// How much this account's daily usage varies, as a coefficient of variation, plus how
    /// many complete days it was measured over.
    ///
    /// Only the *shape* is taken from the transcripts, never the level. The weekly limit
    /// counts usage this app cannot see — other machines, the desktop app, claude.ai — so an
    /// absolute points-per-day read off local tokens would be wrong by whatever fraction of
    /// the account's work happens elsewhere. A ratio of spread to mean survives that: it is
    /// unchanged by any constant factor between local tokens and the limit they consume.
    ///
    /// Today is excluded because it is a partial day, and a partial day is not a small day.
    /// The result is clamped: a fortnight containing one enormous day and thirteen empty ones
    /// produces a coefficient that would swamp any projection, and a fortnight of identical
    /// days produces one near zero, which is a claim about the future that no fortnight
    /// supports.
    public static func dailyVariation(
        events: [UsageEvent], now: Date, calendar: Calendar = .current
    ) -> (coefficient: Double, days: Int)? {
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -variationDays, to: today)
        else { return nil }

        var totals: [Date: Double] = [:]
        for event in events where event.model != syntheticModel {
            guard event.timestamp >= earliest, event.timestamp < today else { continue }
            totals[calendar.startOfDay(for: event.timestamp), default: 0] += weight(event.tokens)
        }

        // Zero-filled: a day with no work is a real observation about how this account is
        // used, and dropping it would report the variability of only the busy days.
        var series: [Double] = []
        for offset in 1...variationDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            series.append(totals[calendar.startOfDay(for: day)] ?? 0)
        }
        guard series.count >= minimumVariationDays else { return nil }
        guard let firstUsed = totals.keys.min() else { return nil }

        // Days before the transcripts begin are absence of evidence, not idle days, so the
        // series is cut at the earliest day with any recorded work.
        let observed = series.enumerated().compactMap { offset, value -> Double? in
            guard let day = calendar.date(byAdding: .day, value: -(offset + 1), to: today),
                calendar.startOfDay(for: day) >= calendar.startOfDay(for: firstUsed)
            else { return nil }
            return value
        }
        guard observed.count >= minimumVariationDays else { return nil }

        let count = Double(observed.count)
        let mean = observed.reduce(0, +) / count
        guard mean > 0 else { return nil }
        let variance = observed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (count - 1)
        let coefficient = variance.squareRoot() / mean
        guard coefficient.isFinite else { return nil }
        return (min(max(coefficient, 0.25), 2.0), observed.count)
    }

    // MARK: Projection

    /// Projects `kind` forward to its reset. `nil` only when the snapshot has no such window.
    ///
    /// `resetsAt` is taken from the snapshot on every call rather than remembered, because the
    /// 5-hour window's reset time drifts forward between polls.
    public static func project(
        kind: WindowKind, snapshot: UsageSnapshot, samples: [Sample],
        events: [UsageEvent], now: Date
    ) -> Projection? {
        guard let window = (kind == .fiveHour ? snapshot.fiveHour : snapshot.sevenDay) else {
            return nil
        }
        let currentPercent = window.utilization
        let resetsAt = window.resetsAt

        // The weekly window is fixed and days away, so it is paced rather than fitted. Falls
        // through to the regression only when the snapshot carries no reset instant, without
        // which "how far into the window are we" has no answer.
        if kind == .sevenDay, let resetsAt,
            let paced = pacedProjection(
                kind: kind, currentPercent: currentPercent, resetsAt: resetsAt,
                events: events, now: now)
        {
            return paced
        }

        return fittedProjection(
            kind: kind, currentPercent: currentPercent, resetsAt: resetsAt,
            samples: samples, events: events, now: now)
    }

    /// The rolling-window path: a regression over the trailing poll series, carried to the
    /// reset, with a prediction interval from the residuals.
    private static func fittedProjection(
        kind: WindowKind, currentPercent: Double, resetsAt: Date?,
        samples: [Sample], events: [UsageEvent], now: Date
    ) -> Projection {
        let hoursUntilReset = resetsAt.map { max(0, $0.timeIntervalSince(now)) / 3600 }

        let basis: ProjectionBasis
        let percentPerHour: Double
        let sampleCount: Int
        var band: Double?

        if let measured = fit(samples, kind: kind, now: now) {
            basis = .measured
            percentPerHour = measured.percentPerHour
            sampleCount = measured.sampleCount
            band = hoursUntilReset.map { halfWidth(fit: measured, hours: $0) }
        } else {
            basis = .estimated
            percentPerHour = estimatedRate(
                events: events, kind: kind, currentPercent: currentPercent, now: now,
                resetsAt: resetsAt)
            sampleCount = usableSamples(samples, kind: kind, now: now).count
        }

        var projectedAtReset: Double? = hoursUntilReset.flatMap { hours in
            clampedProjection(currentPercent + percentPerHour * hours)
        }
        withdrawIfUninformative(
            band: &band, projection: &projectedAtReset, currentPercent: currentPercent)

        return Projection(
            kind: kind,
            basis: basis,
            percentPerHour: percentPerHour,
            currentPercent: currentPercent,
            timeToCap: capTime(
                currentPercent: currentPercent, percentPerHour: percentPerHour,
                resetsAt: resetsAt, now: now),
            projectedAtReset: projectedAtReset,
            projectedBand: band,
            resetsAt: resetsAt,
            sampleCount: sampleCount
        )
    }

    /// The fixed-window path: the window's own accumulated total over how long it has been
    /// open, carried forward at that average.
    ///
    /// This needs no poll history at all — the snapshot already says how much of the window is
    /// gone and how much of the budget went with it — which is why it is right from the first
    /// reading, where a regression needs 45 minutes to say anything and then says something
    /// absurd. On a real mid-week snapshot the two disagree by a factor of four: pacing 39%,
    /// regression 171%, on a week that was 22% used with three days left.
    ///
    /// The interval comes from how much this account's daily usage actually varies, which is
    /// the dominant unknown over a horizon measured in days. Summing `d` further days each
    /// drawn from a distribution estimated over `n` of them gives `Var = σ²·(d + d²/n)`: the
    /// first term is the scatter of the days themselves, the second the error in the mean
    /// being carried across all of them.
    private static func pacedProjection(
        kind: WindowKind, currentPercent: Double, resetsAt: Date,
        events: [UsageEvent], now: Date
    ) -> Projection? {
        let windowStart = resetsAt.addingTimeInterval(-kind.nominalDuration)
        let elapsedHours = now.timeIntervalSince(windowStart) / 3600
        // A window ten minutes old has consumed a whole percentage point of nothing: dividing
        // by that elapsed time turns the quantization step itself into a runaway rate.
        guard elapsedHours >= minimumElapsedHours, currentPercent.isFinite else { return nil }

        let remainingHours = max(0, resetsAt.timeIntervalSince(now) / 3600)
        let ratePerHour = max(0, currentPercent) / elapsedHours
        var projectedAtReset: Double? = clampedProjection(
            currentPercent + ratePerHour * remainingHours)

        var band: Double?
        if let variation = dailyVariation(events: events, now: now), remainingHours > 0 {
            let daysRemaining = remainingHours / 24
            let sigmaPerDay = variation.coefficient * ratePerHour * 24
            let spread = daysRemaining + daysRemaining * daysRemaining / Double(variation.days)
            band = confidenceT(df: variation.days - 1) * sigmaPerDay * spread.squareRoot()
        }
        withdrawIfUninformative(
            band: &band, projection: &projectedAtReset, currentPercent: currentPercent)

        return Projection(
            kind: kind,
            basis: .paced,
            percentPerHour: ratePerHour,
            currentPercent: currentPercent,
            timeToCap: capTime(
                currentPercent: currentPercent, percentPerHour: ratePerHour,
                resetsAt: resetsAt, now: now),
            projectedAtReset: projectedAtReset,
            projectedBand: band,
            resetsAt: resetsAt,
            sampleCount: 0
        )
    }

    private static let minimumElapsedHours: Double = 1

    /// Past the informative width the *projection* goes too, not just the band.
    ///
    /// Dropping the band alone is what produced the weekly row's worst reading: "171% at
    /// reset" with no error bar, from a rate fitted over 45 minutes and carried across three
    /// days. Hiding the ± there does not make the number safer to read, it removes the only
    /// thing on the row that said not to trust it. A forecast this app cannot put an interval
    /// on is a forecast it should not print.
    private static func withdrawIfUninformative(
        band: inout Double?, projection: inout Double?, currentPercent: Double
    ) {
        guard let halfWidth = band else { return }
        if !bandIsInformative(halfWidth, currentPercent: currentPercent) {
            band = nil
            projection = nil
        }
    }

    /// Non-finite in, nothing out: a corrupt payload must read as a missing projection rather
    /// than reach Swift Charts, where `min`/`max` pass NaN straight through.
    private static func clampedProjection(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), displayCeiling)
    }

    /// When the fitted line crosses 100%. Unclamped by `displayCeiling` on purpose: the
    /// projection may be capped for display, but the time the cap is hit must stay honest.
    private static func capTime(
        currentPercent: Double, percentPerHour: Double, resetsAt: Date?, now: Date
    ) -> Date? {
        guard percentPerHour.isFinite, percentPerHour > 0, currentPercent.isFinite else {
            return nil
        }
        let hours = max(0, (100 - currentPercent) / percentPerHour)
        guard hours.isFinite else { return nil }
        let cap = now.addingTimeInterval(hours * 3600)
        if let resetsAt, cap > resetsAt { return nil }
        return cap
    }
}
