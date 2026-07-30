import Foundation
import SwiftUI
import UsageCore

/// The recent-sessions list: project, how long ago it started, how long it ran, and what it
/// spent. Content only — `PanelView` owns the `DisclosureGroup` and puts the count in its label.
///
/// Capped at `maximumRows`; the remainder is acknowledged with a count rather than dropped
/// silently, because `Aggregates.sessions` splits one transcript session into several stats and
/// the total is easily larger than it looks.
struct SessionsSection: View {
    /// The panel does not scroll, so the list has a hard ceiling.
    static let maximumRows = 8

    private let sessions: [SessionStat]
    private let now: Date

    /// `now` defaults so the panel can call `SessionsSection(sessions:)`; passing it explicitly
    /// keeps the relative times deterministic in previews and tests.
    init(sessions: [SessionStat], now: Date = Date()) {
        self.sessions = sessions
        self.now = now
    }

    var body: some View {
        if sessions.isEmpty {
            Text("No sessions in the local transcripts yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(sessions.prefix(Self.maximumRows)) { session in
                    row(session)
                }
                if sessions.count > Self.maximumRows {
                    Text("+\(sessions.count - Self.maximumRows) older")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Row

    private func row(_ session: SessionStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.projectName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(UsageNumberFormat.ago(session.start, from: now))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(UsageNumberFormat.compactDuration(session.duration))
                dot
                Text(UsageNumberFormat.messages(session.messageCount))
                dot
                // Input side and output separately rather than one total: they differ by orders of
                // magnitude and price differently, so a single figure hides which one moved.
                Text("\(UsageNumberFormat.tokens(inputSide(session.tokens))) in")
                dot
                Text("\(UsageNumberFormat.tokens(session.tokens.output)) out")
                Spacer(minLength: 4)
                Text(UsageNumberFormat.cost(session.costEquivalent))
                    .help("Equivalent cost at published API rates — subscription usage is not billed per token.")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spokenSummary(session)))
    }

    private var dot: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }

    /// Everything on the request side of the exchange: fresh input plus both halves of the cache.
    /// Output is excluded because it is generated, not sent.
    private func inputSide(_ tokens: TokenCounts) -> Int {
        tokens.input + tokens.cacheRead + tokens.cacheCreate
    }

    private func spokenSummary(_ session: SessionStat) -> String {
        let parts = [
            session.projectName,
            "started \(UsageNumberFormat.ago(session.start, from: now))",
            "ran \(UsageNumberFormat.compactDuration(session.duration))",
            UsageNumberFormat.messages(session.messageCount),
            "\(UsageNumberFormat.tokens(inputSide(session.tokens))) input tokens",
            "\(UsageNumberFormat.tokens(session.tokens.output)) output tokens",
            "\(UsageNumberFormat.cost(session.costEquivalent)) equivalent",
        ]
        return parts.joined(separator: ", ")
    }
}
