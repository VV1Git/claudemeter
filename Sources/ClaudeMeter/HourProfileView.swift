import Charts
import Foundation
import SwiftUI
import UsageCore

/// Limit-weighted spend by local hour of day, over the trailing month.
///
/// Weighted rather than raw tokens, so the bars answer when the *limit* is being consumed
/// rather than when the most text moved — an hour of Opus output and an hour of cache reads
/// are wildly different claims on a rate limit and nearly the same token count.
///
/// The peak hour is called out below the chart because the shape alone does not say which
/// column is which: the bars are three points wide at this size and the axis can only afford
/// labels every six hours.
struct HourProfileView: View {
    private let buckets: [HourBucket]

    init(buckets: [HourBucket]) {
        self.buckets = buckets
    }

    private static let height: CGFloat = 72

    private var peak: Double {
        buckets.map(\.weighted).max() ?? 0
    }

    private var total: Double {
        buckets.reduce(0) { $0 + $1.weighted }
    }

    var body: some View {
        if buckets.isEmpty || peak <= 0 {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: 5) {
                chart
                    .frame(height: Self.height)
                footer
            }
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            // Plotted against an instant with `unit: .hour`, not against the hour number.
            // A bare numeric x-axis gives Charts no band to size a bar within, and the bars
            // render at zero width — visible as an empty plot with a correct axis under it.
            // `DailyBarsView` has always done it this way; this had to learn.
            BarMark(
                x: .value("Hour", Self.instant(for: bucket.hour), unit: .hour),
                y: .value("Weighted tokens", bucket.weighted)
            )
            .cornerRadius(1.5)
            // The busiest hour at full strength and the rest receding, so the shape reads as a
            // profile rather than as twenty-four equally weighted claims.
            .foregroundStyle(
                Color.accentColor.opacity(bucket.weighted >= peak ? 1 : 0.55))
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(peak, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.hourLabel(Calendar.current.component(.hour, from: date)))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    /// An instant on an arbitrary reference day standing for `hour` of the local clock.
    ///
    /// Built by component rather than by adding `hour * 3600` to midnight, so the two days a
    /// year that are not 24 hours long cannot shift a bucket into its neighbour's slot.
    private static func instant(for hour: Int) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight) ?? midnight
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            Text("No activity recorded in the last 30 days.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: Self.height)
    }

    @ViewBuilder private var footer: some View {
        if let busiest = buckets.max(by: { $0.weighted < $1.weighted }), busiest.weighted > 0 {
            Text(
                "Busiest \(Self.hourLabel(busiest.hour))–\(Self.hourLabel((busiest.hour + 1) % 24))"
                    + " · \(UsageNumberFormat.share(share(of: busiest))) of the month's weighted spend"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func share(of bucket: HourBucket) -> Double {
        guard total > 0 else { return 0 }
        return bucket.weighted / total
    }

    /// `9am`, `12pm`, `6pm` — narrow enough to sit under a three-point bar.
    private static func hourLabel(_ hour: Int) -> String {
        let wrapped = ((hour % 24) + 24) % 24
        let suffix = wrapped < 12 ? "am" : "pm"
        let display = wrapped % 12 == 0 ? 12 : wrapped % 12
        return "\(display)\(suffix)"
    }

    private var accessibilitySummary: String {
        guard let busiest = buckets.max(by: { $0.weighted < $1.weighted }), busiest.weighted > 0
        else { return "No activity recorded in the last 30 days." }
        return "Usage by hour of day over the last 30 days. Busiest hour "
            + "\(Self.hourLabel(busiest.hour)), carrying "
            + "\(UsageNumberFormat.share(share(of: busiest))) of weighted spend."
    }
}
