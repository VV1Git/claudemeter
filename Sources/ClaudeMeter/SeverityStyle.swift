import SwiftUI
import UsageCore

// MARK: - Severity colour

/// The one severity-to-colour mapping in the app.
///
/// The thresholds themselves live in `UsageCore` (`Severity.fromPercent`, and the API's own
/// `severity` field when it sends one), so nothing here looks at a percentage: callers pass the
/// `Severity` they were handed by `UsageSnapshot.severity(for:)`. Every colour is semantic, so
/// light and dark and a custom accent colour all come out right without a second code path.
enum SeverityStyle {
    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .normal: Color.accentColor
        case .warning: Color.orange
        case .critical: Color.red
        }
    }

    /// Unfilled part of a meter. Derived from `Color.primary` so it inverts with the appearance
    /// instead of being a fixed grey that disappears in one of the two modes.
    static let track = Color.primary.opacity(0.10)

    /// Height of every capsule meter in the panel.
    static let barHeight: CGFloat = 6
}
