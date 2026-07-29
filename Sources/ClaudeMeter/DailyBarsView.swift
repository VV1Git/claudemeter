import Charts
import Foundation
import SwiftUI
import UsageCore

/// Total tokens per day over the range `Aggregates.daily` produced, plus the range totals.
///
/// `Aggregates.daily` zero-fills, so an inactive day is a real gap in the bars rather than a
/// missing category, and the x-axis stays evenly spaced without any padding here.
struct DailyBarsView: View {
    private let daily: [DailyStat]

    init(daily: [DailyStat]) {
        self.daily = daily
    }

    private static let height: CGFloat = 88

    private var peakTokens: Int {
        daily.map { $0.tokens.total }.max() ?? 0
    }

    var body: some View {
        if daily.isEmpty || peakTokens == 0 {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: 5) {
                chart
                    .frame(height: Self.height)
                footer
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart(daily) { stat in
            // Plotted as `Double` so the mark's value type matches the y-scale domain below.
            BarMark(
                x: .value("Day", stat.day, unit: .day),
                y: .value("Tokens", Double(stat.tokens.total))
            )
            .cornerRadius(1.5)
            // Today is a partial day, so it is drawn at full strength and the settled days
            // recede — otherwise the last bar reads as a drop in usage.
            .foregroundStyle(
                Color.accentColor.opacity(Calendar.current.isDateInToday(stat.day) ? 1 : 0.7))
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...Double(max(peakTokens, 1)))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(UsageNumberFormat.tokens(Int(tokens)))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 10)) { value in
                AxisValueLabel {
                    if let day = value.as(Date.self) {
                        Text(day.formatted(.dateTime.month(.abbreviated).day()))
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

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(UsageNumberFormat.tokens(totalTokens)) tokens")
            Spacer(minLength: 4)
            Text("\(UsageNumberFormat.cost(totalCost)) equiv")
                .help("Equivalent cost at published API rates — subscription usage is not billed per token.")
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            Text("No tokens recorded in this range.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: Self.height)
    }

    // MARK: Totals

    private var totalTokens: Int {
        daily.reduce(0) { $0 + $1.tokens.total }
    }

    private var totalCost: Double {
        daily.reduce(0) { $0 + $1.costEquivalent }
    }

    private var accessibilitySummary: String {
        "Daily tokens over \(daily.count) days, \(UsageNumberFormat.tokens(totalTokens)) total"
    }
}
