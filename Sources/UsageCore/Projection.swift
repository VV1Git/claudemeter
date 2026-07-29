import Foundation

// MARK: - Burn rate fit

/// A least-squares fit of utilization against time over the trailing poll series.
///
/// Carried separately from `Projection` so the regression quality (`standardErrorOfSlope`,
/// `spanHours`) stays inspectable: the UI has to be able to tell a rate measured over
/// 40 minutes of steady polling from one scraped off four noisy points.
public struct BurnRateFit: Sendable, Equatable {
    /// Slope in percentage points per hour. Negative is a legitimate result, not an
    /// error — the 5-hour window is rolling, so utilization falls whenever usage ages
    /// out faster than it accrues.
    public let percentPerHour: Double
    /// Fitted utilization at the *first* sample of the usable series, not at `now`. The
    /// series slides forward every poll, so this is the anchor the slope was measured
    /// from rather than a stable baseline.
    public let interceptPercent: Double
    /// Standard error of `percentPerHour`, in points per hour. Zero for a perfect fit.
    public let standardErrorOfSlope: Double
    public let sampleCount: Int
    public let spanHours: Double

    public init(
        percentPerHour: Double, interceptPercent: Double, standardErrorOfSlope: Double,
        sampleCount: Int, spanHours: Double
    ) {
        self.percentPerHour = percentPerHour
        self.interceptPercent = interceptPercent
        self.standardErrorOfSlope = standardErrorOfSlope
        self.sampleCount = sampleCount
        self.spanHours = spanHours
    }
}

// MARK: - Projection engine

/// Turns the persisted poll series into a burn rate and a projection to the window reset.
///
/// Everything here is pure: no filesystem, no network. The caller owns the samples and
/// the snapshot, which is what makes the reset-detection rules testable.
public enum ProjectionEngine {
    /// How far back to fit. Short enough that a change of pace shows up within a few
    /// polls, long enough to average out the granularity of the API's own percentages.
    public static let trailingWindow: TimeInterval = 45 * 60
    public static let minimumSamples = 4
    public static let minimumSpan: TimeInterval = 10 * 60
    /// Drop between consecutive polls, in percentage points, that counts as a reset.
    public static let resetDropThreshold: Double = 20
    /// Confidence bands wider than this say nothing useful, so they are hidden rather
    /// than drawn as a band spanning the whole chart.
    public static let maximumBandToShow: Double = 40

    /// 95% two-sided normal quantile.
    private static let confidenceZ: Double = 1.96
    /// Ceiling for the *displayed* projection. `timeToCap` is left unclamped.
    private static let displayCeiling: Double = 200
    private static let syntheticModel = "<synthetic>"

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

    /// A falling percentage is *not* a reset. The 5-hour window is rolling — utilization was
    /// observed sliding 17% → 2% purely by ageing out, with `resets_at` drifting forward the
    /// whole time. Only a cliff of at least `resetDropThreshold` points between consecutive
    /// polls, or a gap longer than the window itself, starts a new series.
    private static func isResetBoundary(_ previous: Sample, _ next: Sample, kind: WindowKind) -> Bool {
        if next.t.timeIntervalSince(previous.t) > kind.nominalDuration { return true }
        guard let before = previous.percent(for: kind), let after = next.percent(for: kind) else {
            return false
        }
        return before - after >= resetDropThreshold
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
        let standardError = (variance / sumXX).squareRoot()

        return BurnRateFit(
            percentPerHour: slope,
            interceptPercent: intercept,
            standardErrorOfSlope: standardError,
            sampleCount: points.count,
            spanHours: span / 3600
        )
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
    public static func estimatedRate(
        events: [UsageEvent], kind: WindowKind, currentPercent: Double, now: Date
    ) -> Double {
        guard currentPercent > 0 else { return 0 }
        let windowStart = now.addingTimeInterval(-kind.nominalDuration)
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
    private static func weight(_ tokens: TokenCounts) -> Double {
        let split = tokens.cacheCreate5m + tokens.cacheCreate1h
        let cacheWrite = split > 0
            ? Double(tokens.cacheCreate5m) * 1.25 + Double(tokens.cacheCreate1h) * 2.0
            : Double(tokens.cacheCreate) * 1.25
        return Double(tokens.input)
            + Double(tokens.output) * 5.0
            + Double(tokens.cacheRead) * 0.1
            + cacheWrite
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
        let hoursUntilReset = resetsAt.map { max(0, $0.timeIntervalSince(now)) / 3600 }

        let basis: ProjectionBasis
        let percentPerHour: Double
        let sampleCount: Int
        var band: Double?

        if let measured = fit(samples, kind: kind, now: now) {
            basis = .measured
            percentPerHour = measured.percentPerHour
            sampleCount = measured.sampleCount
            if let hours = hoursUntilReset {
                let halfWidth = confidenceZ * measured.standardErrorOfSlope * hours
                band = halfWidth <= maximumBandToShow ? halfWidth : nil
            }
        } else {
            basis = .estimated
            percentPerHour = estimatedRate(
                events: events, kind: kind, currentPercent: currentPercent, now: now)
            sampleCount = usableSamples(samples, kind: kind, now: now).count
        }

        let projectedAtReset = hoursUntilReset.map { hours in
            min(max(currentPercent + percentPerHour * hours, 0), displayCeiling)
        }

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

    /// When the fitted line crosses 100%. Unclamped by `displayCeiling` on purpose: the
    /// projection may be capped for display, but the time the cap is hit must stay honest.
    private static func capTime(
        currentPercent: Double, percentPerHour: Double, resetsAt: Date?, now: Date
    ) -> Date? {
        guard percentPerHour > 0 else { return nil }
        let hours = max(0, (100 - currentPercent) / percentPerHour)
        let cap = now.addingTimeInterval(hours * 3600)
        if let resetsAt, cap > resetsAt { return nil }
        return cap
    }
}
