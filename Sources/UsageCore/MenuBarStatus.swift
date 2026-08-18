import Foundation

/// The badge shown beside the menu bar ring when the figures behind it are not live.
///
/// The ring alone cannot say this. It draws the last percentage it was given and goes on drawing
/// it, so a meter that stopped updating an hour ago looks exactly like one that updated a second
/// ago — the reading is stale and confidently rendered, which is worse than no reading. The badge
/// is the one place the difference is visible without opening the panel.
///
/// One rule, deliberately: a badge means *the number beside it is not live*. Not "something is
/// wrong" — an expired token with a healthy app is not wrong — and not "act now", since two of
/// these clear themselves. `symbol` says which kind of not-live it is and `description` says it in
/// words, and the two are defined together here so a badge can never appear with a tooltip that
/// describes a different state.
///
/// Lives in `UsageCore` beside `MenuBarLabelText`, and for the same reason: a `MenuBarExtra` label
/// can only be built from `Text` and `Image`, so the whole decision collapses to a symbol name and
/// a string, and strings are testable without instantiating SwiftUI.
public struct MenuBarStatus: Sendable, Equatable {
    /// SF Symbol name. All of these ship in macOS 14, which is the deployment target.
    public let symbol: String
    /// Accessibility label and tooltip. Written to be read on its own, without the ring for
    /// context, because that is how VoiceOver will announce it.
    public let description: String

    public init(symbol: String, description: String) {
        self.symbol = symbol
        self.description = description
    }

    /// The badge for a health state, or `nil` when the meter is live and the ring speaks for
    /// itself.
    ///
    /// Exhaustive over `DataHealth` on purpose — no `default` — so a case added later is a
    /// compile error here rather than a state that silently stops being announced.
    public static func forHealth(_ health: DataHealth) -> MenuBarStatus? {
        switch health {
        case .live:
            return nil
        case .needsAuthorization:
            // The only one a click fixes, and the reason this type exists: without it the app
            // waits for a user who has no way of knowing they are being waited for.
            return MenuBarStatus(
                symbol: "lock.fill",
                description: "ClaudeMeter needs Keychain access. Open it and choose Authorize.")
        case .waitingForClaudeCode:
            return MenuBarStatus(
                symbol: "hourglass",
                description: "The token has aged out. Run any `claude` command to refresh it.")
        case .staleCredentials:
            return MenuBarStatus(
                symbol: "exclamationmark.triangle.fill",
                description: "The token can no longer be renewed. Sign in to Claude Code again.")
        case .noCredentials:
            return MenuBarStatus(
                symbol: "person.crop.circle.badge.questionmark",
                description: "Not signed in to Claude Code.")
        case .offline:
            return MenuBarStatus(
                symbol: "wifi.slash",
                description: "Cannot reach the usage endpoint. Showing the last reading.")
        }
    }
}
