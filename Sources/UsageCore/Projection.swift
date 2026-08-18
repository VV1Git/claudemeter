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
    ///
    /// Internal rather than private so `Projection.projectedHigh` clamps the top of its
    /// interval to the same ceiling the centre is clamped to; `private` at type scope is
    /// file-scoped, and that property lives in `Models.swift`.
    static let displayCeiling: Double = 200
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
    /// at 5% is noise; the same forty points on a window at 80% is the whole question.
    ///
    /// This no longer suppresses anything. It gated a rule that deleted the whole forecast when
    /// the interval grew past it, which is how both rows came to print a pace and nothing about
    /// where the window was heading. Both paths now state the interval instead, and this is
    /// kept as what it always described: whether a band is narrow enough to act on.
    public static func bandIsInformative(_ halfWidth: Double, currentPercent: Double) -> Bool {
        guard halfWidth.isFinite, halfWidth >= 0 else { return false }
        return halfWidth <= max(10, min(maximumBandToShow, (100 - currentPercent) * 0.5))
    }

    // MARK: Series selection

    /// The samples a chart of one whole period should plot: those inside `period`, ascending,
    /// cut at the most recent reset boundary.
    ///
    /// Separate from `usableSamples` because the two want different spans — a regression wants
    /// the trailing 45 minutes, a chart wants the window — but they must agree about where a
    /// cycle ended, so both segment on `isResetBoundary`.
    public static func chartSamples(
        _ samples: [Sample], kind: WindowKind, period: (start: Date, end: Date)
    ) -> [Sample] {
        // Two-sided comparison rather than a `ClosedRange.contains`: both comparisons are false
        // for a NaN-backed timestamp, so a corrupt sample is dropped rather than admitted.
        let series = samples
            .filter { $0.t >= period.start && $0.t <= period.end && $0.percent(for: kind) != nil }
            .sorted { $0.t < $1.t }
        guard series.count > 1 else { return series }

        var start = 0
        for i in 1..<series.count where isResetBoundary(series[i - 1], series[i], kind: kind) {
            start = i
        }
        return Array(series[start...])
    }

    /// Trailing-window samples for `kind`, ascending, cut at the most recent reset boundary.
    ///
    /// Samples missing a percentage for `kind` are dropped rather than treated as zero —
    /// the API returns `null` windows routinely and a zero would read as a reset.
    ///
    /// `window` defaults to the regression's trailing span. `ActivitySignal` asks for a longer one
    /// — it is differencing whole percentage points rather than fitting a line through them, and
    /// needs a stretch the window can have moved measurably across.
    public static func usableSamples(
        _ samples: [Sample], kind: WindowKind, now: Date, window: TimeInterval = trailingWindow
    ) -> [Sample] {
        let cutoff = now.addingTimeInterval(-window)
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
    /// Public because the chart segments on this same rule. `SparklineView` used to restate it
    /// as a percentage-drop test alone, and on this account's live data that missed a real
    /// turnover: 15% at 13:18:31 falling to 1% at 13:28:32 is a 14-point drop, under
    /// `resetDropThreshold`, while the reset instant jumping 13:20 → 18:20 identifies it at
    /// once. The chart drew a cliff that never happened.
    public static func isResetBoundary(_ previous: Sample, _ next: Sample, kind: WindowKind) -> Bool {
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

    /// The definition lives in `LimitWeight` so the burn-rate fit, the limit calibration and
    /// the usage profiles cannot drift apart about what a token is worth.
    ///
    /// What this does not model is the difference *between* models: an Opus token and a Sonnet
    /// token weigh the same here while consuming the limit at very different rates, so a
    /// session that switches model mid-window miscalibrates until the poll series is long
    /// enough to fit. `LimitCalibration.familySpread` measures that difference where the data
    /// allows it to be separated, which is the beginning of a fix rather than one.
    private static func weight(_ tokens: TokenCounts) -> Double {
        LimitWeight.of(tokens)
    }

    // MARK: Daily variation

    /// Trailing complete days of local usage used to estimate how much a day varies.
    public static let variationDays = 14
    /// Fewer complete days than this and there is no spread worth quoting.
    public static let minimumVariationDays = 4
    /// Bounds on the coefficient of variation. Named rather than inlined because
    /// `pacedProjection` substitutes the ceiling when there is no measured variation at all,
    /// and a substitute that drifted away from the clamp it is meant to be the top of would
    /// quietly become a *narrower* interval than the engine's own worst case.
    public static let variationFloor: Double = 0.25
    public static let variationCeiling: Double = 2.0

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
        // Bucketed through `LocalDayIndex` rather than by `startOfDay` per event, for the reason
        // that type documents: this runs on the main actor on every poll, and a calendar call per
        // event over a fortnight of a large corpus is tens of milliseconds of it.
        guard let index = LocalDayIndex(days: variationDays, endingAt: now, calendar: calendar)
        else { return nil }

        // Zero-filled: a day with no work is a real observation about how this account is
        // used, and dropping it would report the variability of only the busy days.
        var totals = [Double](repeating: 0, count: index.dayCount)
        var firstUsed: Int?
        for event in events where event.model != syntheticModel {
            guard let day = index.day(of: event.timestamp) else { continue }
            totals[day] += weight(event.tokens)
            if firstUsed == nil || day < firstUsed! { firstUsed = day }
        }

        // Days before the transcripts begin are absence of evidence, not idle days, so the
        // series is cut at the earliest day with any recorded work.
        guard let firstUsed else { return nil }
        let observed = Array(totals[firstUsed...])
        guard observed.count >= minimumVariationDays else { return nil }

        let count = Double(observed.count)
        let mean = observed.reduce(0, +) / count
        guard mean > 0 else { return nil }
        let variance = observed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (count - 1)
        let coefficient = variance.squareRoot() / mean
        guard coefficient.isFinite else { return nil }
        return (min(max(coefficient, variationFloor), variationCeiling), observed.count)
    }

    /// Trailing complete hours of local usage used to estimate how much an hour varies.
    ///
    /// Two days rather than the fortnight the daily figure takes: the 5-hour window's horizon is
    /// hours, and behaviour from last week says less about the next four hours than yesterday
    /// evening does.
    public static let variationHours = 48
    /// Fewer complete hours than this and there is no spread worth quoting.
    public static let minimumVariationHours = 8

    /// How much this account's hourly usage varies, as a coefficient of variation, plus how
    /// many complete hours it was measured over.
    ///
    /// The hour-scale twin of `dailyVariation`, and it carries the same caveat and the same
    /// defence: only the shape is taken from the transcripts, never the level, because a ratio
    /// of spread to mean is unchanged by whatever constant fraction of the account's work this
    /// machine cannot see.
    ///
    /// The current hour is excluded because it is partial, and a partial hour is not a quiet one.
    public static func hourlyVariation(
        events: [UsageEvent], now: Date, calendar: Calendar = .current
    ) -> (coefficient: Double, hours: Int)? {
        let thisHour = startOfHour(for: now, calendar: calendar)
        let earliest = thisHour.addingTimeInterval(-Double(variationHours) * 3600)

        var totals: [Date: Double] = [:]
        for event in events where event.model != syntheticModel {
            guard event.timestamp >= earliest, event.timestamp < thisHour else { continue }
            totals[startOfHour(for: event.timestamp, calendar: calendar), default: 0]
                += weight(event.tokens)
        }
        guard let firstUsed = totals.keys.min() else { return nil }

        // Zero-filled, and cut at the earliest hour with any recorded work: an idle hour is a
        // real observation, but an hour before the transcripts begin is absence of evidence.
        var observed: [Double] = []
        for offset in 1...variationHours {
            let hour = thisHour.addingTimeInterval(-Double(offset) * 3600)
            guard hour >= firstUsed else { continue }
            observed.append(totals[hour] ?? 0)
        }
        guard observed.count >= minimumVariationHours else { return nil }

        let count = Double(observed.count)
        let mean = observed.reduce(0, +) / count
        guard mean > 0 else { return nil }
        let variance = observed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (count - 1)
        let coefficient = variance.squareRoot() / mean
        guard coefficient.isFinite else { return nil }
        return (min(max(coefficient, variationFloor), variationCeiling), observed.count)
    }

    private static func startOfHour(for date: Date, calendar: Calendar) -> Date {
        calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    // MARK: Projection

    /// Projects `kind` forward to its reset. `nil` only when the snapshot has no such window.
    ///
    /// Three sources, in descending order of what they know:
    ///
    /// 1. the regression over the poll series, for the rolling 5-hour window only;
    /// 2. the window's own consumption over its own elapsed time, which needs no history;
    /// 3. nothing — the current reading carried forward flat.
    ///
    /// Every one of them is drawn from the API's utilization, which is what the account is
    /// actually being charged and therefore counts Claude Code on any machine, the desktop app
    /// and claude.ai alike. This used to fall back to a rate calibrated from *local transcript*
    /// tokens, which cannot see any of that: on an account whose work is split across devices
    /// and surfaces that rate reads zero while the window climbs, and a zero rate took the whole
    /// forecast off the row with it. Transcripts are still read, but only for the *shape* of the
    /// interval — a ratio, unchanged by whatever constant fraction of the work happens elsewhere.
    ///
    /// `resetsAt` is taken from the snapshot on every call rather than remembered, because the
    /// 5-hour window's reset time drifts forward between polls.
    public static func project(
        kind: WindowKind, snapshot: UsageSnapshot, samples: [Sample],
        events: [UsageEvent], now: Date,
        idleGap: TimeInterval = Aggregates.defaultActiveGap, calendar: Calendar = .current
    ) -> Projection? {
        guard let window = (kind == .fiveHour ? snapshot.fiveHour : snapshot.sevenDay) else {
            return nil
        }
        let currentPercent = window.utilization
        let resetsAt = window.resetsAt

        // The weekly window is never fitted: it is fixed and days away, and regressing a
        // 45-minute slope across a 168-hour horizon printed 171% on a week that finished at 23%.
        if kind == .fiveHour, let measured = fit(samples, kind: kind, now: now) {
            return fittedProjection(
                fit: measured, kind: kind, currentPercent: currentPercent, resetsAt: resetsAt,
                now: now)
        }

        if let resetsAt,
            let paced = pacedProjection(
                kind: kind, currentPercent: currentPercent, resetsAt: resetsAt,
                samples: samples, events: events, now: now, idleGap: idleGap, calendar: calendar)
        {
            return paced
        }

        return flatProjection(
            kind: kind, currentPercent: currentPercent, resetsAt: resetsAt,
            samples: samples, now: now)
    }

    /// The rolling-window path: a regression over the trailing poll series, carried to the
    /// reset, with a prediction interval from the residuals.
    private static func fittedProjection(
        fit measured: BurnRateFit, kind: WindowKind, currentPercent: Double, resetsAt: Date?,
        now: Date
    ) -> Projection {
        let hoursUntilReset = resetsAt.map { max(0, $0.timeIntervalSince(now)) / 3600 }
        let percentPerHour = measured.percentPerHour
        let band = hoursUntilReset.map { halfWidth(fit: measured, hours: $0) }

        let projectedAtReset: Double? = hoursUntilReset.flatMap { hours in
            clampedProjection(currentPercent + percentPerHour * hours)
        }

        // No longer withdrawn when the interval is wide. Suppression was written when this path
        // also carried the weekly window, where a slope measured over 45 minutes and multiplied
        // by a 168-hour horizon printed 171% on a week that finished at 23% — a wrong *centre*,
        // which no error bar rescues. The weekly window is paced now and never reaches here, so
        // the only window this path serves is the 5-hour one, whose horizon is at most five
        // hours. A fit that noisy over that span produces a centre near the current reading and
        // a wide interval around it, which is a true statement rather than a misleading one.

        return Projection(
            kind: kind,
            basis: .measured,
            percentPerHour: percentPerHour,
            currentPercent: currentPercent,
            timeToCap: capTime(
                currentPercent: currentPercent, percentPerHour: percentPerHour,
                resetsAt: resetsAt, now: now),
            projectedAtReset: projectedAtReset,
            projectedBand: band,
            resetsAt: resetsAt,
            sampleCount: measured.sampleCount
        )
    }

    /// The last resort: no rate, and the current reading carried forward unchanged.
    ///
    /// Reached when there are too few polls to fit and the window is too young to pace. It
    /// exists so that path still produces a `Projection` — a row that prints nothing about where
    /// a window is heading is indistinguishable from a broken app, and "holding at 28%" is a
    /// true and readable thing to say about a window nobody is spending against.
    private static func flatProjection(
        kind: WindowKind, currentPercent: Double, resetsAt: Date?, samples: [Sample], now: Date
    ) -> Projection {
        Projection(
            kind: kind,
            basis: .flat,
            percentPerHour: 0,
            currentPercent: currentPercent,
            timeToCap: nil,
            projectedAtReset: resetsAt == nil ? nil : clampedProjection(currentPercent),
            projectedBand: nil,
            resetsAt: resetsAt,
            sampleCount: usableSamples(samples, kind: kind, now: now).count
        )
    }

    /// How far the activity profile is allowed to move the measured pace, as a factor either way.
    ///
    /// The pace is `consumed ÷ elapsed activity`, so a profile that thinks the window opened into
    /// hours it expects nothing from divides by nearly nothing. That case is real — a week that
    /// turns over at 04:00 spends its first six hours in the profile's basement — and unbounded:
    /// the floor on an hour is a twentieth, so eight such hours would multiply the pace by twenty
    /// on the strength of four weeks of one machine's transcripts. Four is the most leverage that
    /// evidence supports; past it the shaped rate is clamped and the shape still applies to the
    /// horizon ahead, where it is doing the work it was built for.
    public static let massLeverage: Double = 4

    /// The snapshot path: the window's own accumulated total over how long it has been
    /// open, carried forward at that average — with "how long" measured on the account's own
    /// activity clock rather than on the wall clock.
    ///
    /// This needs no poll history at all — the snapshot already says how much of the window is
    /// gone and how much of the budget went with it — which is why it is right from the first
    /// reading, where a regression needs 45 minutes to say anything and then says something
    /// absurd. On a real mid-week snapshot the two disagree by a factor of four: pacing 39%,
    /// regression 171%, on a week that was 22% used with three days left.
    ///
    /// What it used to get wrong is *which hours it was pacing across*. Dividing by elapsed wall
    /// clock and multiplying by remaining wall clock prices 04:00 on a Sunday exactly like 15:00
    /// on a Tuesday, which no account with a sleep cycle does. `ActivityProfile` supplies the
    /// shape — hour of day times day of week, shrunk toward flat by how many days it was measured
    /// over — and `ActivitySignal` supplies what is happening right now: whether this machine is
    /// mid-burst, how many sub-agents are running in it, how long it has already been running,
    /// and whether the limit itself is climbing faster than the window's own pace expects. The
    /// live term decays back to the profile over a couple of hours, because a burst says a great
    /// deal about the next hour and nearly nothing about the day after tomorrow.
    ///
    /// Under `.uniform` — a new install, or an account with under three complete days of
    /// transcripts — every mass below is exactly a count of wall-clock hours and this reduces,
    /// line for line, to the flat pacing it replaces.
    ///
    /// The interval comes from how much this account's daily usage actually varies, which is
    /// the dominant unknown over a horizon measured in days. Summing `d` further days each
    /// drawn from a distribution estimated over `n` of them gives `Var = σ²·(d + d²/n)`: the
    /// first term is the scatter of the days themselves, the second the error in the mean
    /// being carried across all of them. `d` is counted in mean *days of activity* rather than in
    /// days of clock, so a horizon that is mostly night carries proportionally less of both.
    private static func pacedProjection(
        kind: WindowKind, currentPercent: Double, resetsAt: Date,
        samples: [Sample], events: [UsageEvent], now: Date,
        idleGap: TimeInterval, calendar: Calendar
    ) -> Projection? {
        let windowStart = resetsAt.addingTimeInterval(-kind.nominalDuration)
        let elapsedHours = now.timeIntervalSince(windowStart) / 3600
        // A window ten minutes old has consumed a whole percentage point of nothing: dividing
        // by that elapsed time turns the quantization step itself into a runaway rate.
        guard elapsedHours >= minimumElapsedHours(for: kind), currentPercent.isFinite else {
            return nil
        }

        let remainingHours = max(0, resetsAt.timeIntervalSince(now) / 3600)
        let profile = ActivityProfile.build(events: events, now: now, calendar: calendar)

        // The activity the window has already been open across, clamped to within `massLeverage`
        // of the clock. Both ends of the clamp matter: a week that opened at 04:00 would otherwise
        // divide by nearly nothing, and one that opened into a fortnight's busiest evening would
        // divide by too much.
        let rawElapsedMass = profile.mass(from: windowStart, to: now, calendar: calendar)
        let elapsedMass = min(
            max(rawElapsedMass, elapsedHours / massLeverage), elapsedHours * massLeverage)
        guard elapsedMass > 0 else { return nil }

        // Points per mean hour of activity. Identical to the old points-per-hour under a flat
        // profile, and the unit everything downstream is denominated in.
        let ratePerMass = max(0, currentPercent) / elapsedMass

        let signal = ActivitySignal.measure(
            events: events, samples: samples, kind: kind, profile: profile,
            ratePerMass: ratePerMass, now: now, idleGap: idleGap, calendar: calendar)
        let multiplier = signal?.multiplier ?? 1
        let persistence = signal?.persistence ?? 0

        let remainingMass = profile.boostedMass(
            from: now, to: resetsAt, multiplier: multiplier, persistence: persistence,
            calendar: calendar)
        let gain = ratePerMass * remainingMass
        let projectedAtReset: Double? = clampedProjection(currentPercent + gain)

        // The rate the row quotes is the one the forecast was actually made at: the average over
        // the horizon ahead, not the average over the hours behind. Under a flat profile with no
        // live signal the two are the same number; under a shaped one they are not, and quoting
        // the historical figure beside a forecast built from a different one would leave the two
        // unable to be reconciled by anybody reading the row.
        let percentPerHour = remainingHours > 0 ? gain / remainingHours : ratePerMass

        var band: Double?
        if remainingHours > 0 {
            // How much this account varies over the unit the horizon is measured in: days for a
            // week away, hours for an afternoon. Only the *shape* is taken from the transcripts,
            // never the level — a coefficient of variation is a ratio, and a ratio survives
            // whatever constant fraction of the account's work this machine cannot see.
            //
            // No measured variation is not evidence of *low* variation, so an account with too
            // little history gets the widest coefficient this engine will ever believe over the
            // fewest units it will ever accept. Falling through with no band at all was the
            // worse failure: it printed a bare paced number.
            let unitHours = variationUnitHours(for: kind)
            let variation = measuredVariation(
                kind: kind, events: events, now: now, calendar: calendar)
                ?? (coefficient: variationCeiling, count: minimumVariationCount(for: kind))
            // Units of *activity* rather than of clock. Two of the three days left in a week
            // being nights and a weekend does not merely lower the centre of the forecast; it
            // lowers how much those days can vary, because most of what could have varied is time
            // nobody was ever going to spend.
            let unitsRemaining = remainingMass / unitHours
            let sigmaPerUnit = variation.coefficient * ratePerMass * unitHours
            let spread = unitsRemaining + unitsRemaining * unitsRemaining / Double(variation.count)
            let halfWidth = confidenceT(df: variation.count - 1) * sigmaPerUnit * spread.squareRoot()
            band = halfWidth.isFinite ? halfWidth : nil
        }

        let shape = ForecastShape(
            elapsedHours: elapsedHours,
            elapsedMass: elapsedMass,
            remainingHours: remainingHours,
            remainingMass: remainingMass,
            ratePerMass: ratePerMass,
            activityMultiplier: multiplier,
            persistence: persistence,
            runningAgents: signal?.runningAgents ?? 0,
            profileDays: profile.observedDays,
            quietHours: profile.quietHours(from: now, to: resetsAt, calendar: calendar),
            profile: profile)

        // A wide interval is rendered, never withdrawn. Pacing's centre is the window's own
        // consumption over the window's own elapsed time — arithmetic on two observed
        // quantities rather than an extrapolation — so the only thing that can go wrong here is
        // imprecision, and imprecision is what a `±` is for.
        //
        // The width is not hypothetical. This account's daily coefficient of variation is 2.28
        // (one 135M-token day among fourteen, seven of them empty), clamped to 2.0, which puts
        // the interval past ±50 points. Under the rule that used to delete a forecast once its
        // interval grew past a threshold, every weekly reading this account produced was
        // suppressed, and the row showed no forecast at all.

        return Projection(
            kind: kind,
            basis: .paced,
            percentPerHour: percentPerHour,
            currentPercent: currentPercent,
            timeToCap: shapedCapTime(
                currentPercent: currentPercent, ratePerMass: ratePerMass, profile: profile,
                multiplier: multiplier, persistence: persistence, resetsAt: resetsAt, now: now,
                calendar: calendar),
            projectedAtReset: projectedAtReset,
            projectedBand: band,
            resetsAt: resetsAt,
            sampleCount: 0,
            shape: shape
        )
    }

    /// How long a window must have been open before its own average is worth quoting, as a
    /// fraction of the window's own length.
    ///
    /// A flat hour was two rules wearing one name: 0.6% of a week, and 20% of a five-hour
    /// window. A twentieth is one rule — 15 minutes for the 5-hour window, 8.4 hours for the
    /// weekly one — and it is the same statement in both places: a window is not paced from its
    /// first few percent, where the reporting quantum is a large share of everything observed.
    public static let minimumElapsedFraction: Double = 1.0 / 20

    public static func minimumElapsedHours(for kind: WindowKind) -> Double {
        kind.nominalDuration / 3600 * minimumElapsedFraction
    }

    /// The unit the horizon is counted in: days for the weekly window, hours for the 5-hour one.
    private static func variationUnitHours(for kind: WindowKind) -> Double {
        kind == .sevenDay ? 24 : 1
    }

    private static func minimumVariationCount(for kind: WindowKind) -> Int {
        kind == .sevenDay ? minimumVariationDays : minimumVariationHours
    }

    private static func measuredVariation(
        kind: WindowKind, events: [UsageEvent], now: Date, calendar: Calendar = .current
    ) -> (coefficient: Double, count: Int)? {
        switch kind {
        case .sevenDay:
            return dailyVariation(events: events, now: now, calendar: calendar)
                .map { (coefficient: $0.coefficient, count: $0.days) }
        case .fiveHour:
            return hourlyVariation(events: events, now: now, calendar: calendar)
                .map { (coefficient: $0.coefficient, count: $0.hours) }
        }
    }

    /// Non-finite in, nothing out: a corrupt payload must read as a missing projection rather
    /// than reach Swift Charts, where `min`/`max` pass NaN straight through.
    private static func clampedProjection(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), displayCeiling)
    }

    /// When the shaped forecast crosses 100%: the instant by which enough *activity* has accrued
    /// to spend the headroom, rather than enough clock.
    ///
    /// This is where the shape is most visible to a reader. A window with 12 points of headroom
    /// and a pace of one point per active hour does not cap twelve hours from now if nine of
    /// those hours are the middle of the night — it caps some time tomorrow morning, and saying
    /// so is the difference between a warning that can be acted on and one that cannot. The
    /// live multiplier is carried into it too, so a fan-out running right now pulls the estimate
    /// in rather than leaving the row to discover the cap when it arrives.
    ///
    /// Returns nil when the cap is further out than the reset, matching `capTime`.
    private static func shapedCapTime(
        currentPercent: Double, ratePerMass: Double, profile: ActivityProfile,
        multiplier: Double, persistence: TimeInterval, resetsAt: Date, now: Date, calendar: Calendar
    ) -> Date? {
        guard ratePerMass.isFinite, ratePerMass > 0, currentPercent.isFinite,
            currentPercent < 100, resetsAt > now
        else { return nil }
        let headroom = (100 - currentPercent) / ratePerMass
        return profile.instant(
            reachingMass: headroom, from: now, by: resetsAt, multiplier: multiplier,
            persistence: persistence, calendar: calendar)
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
