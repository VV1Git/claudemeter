import Foundation
import Testing

import UsageCore

/// The badge exists so a stopped meter cannot pass for a live one. These check the property that
/// makes that true — every non-live state is announced, and the live one is not — rather than the
/// particular glyphs, which are a design choice and may change.
@Suite("Menu bar status badge")
struct MenuBarStatusTests {
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every state the app can actually be in, so a case that stops being announced fails here
    /// rather than going quiet in the menu bar.
    private static let allStates: [DataHealth] = [
        .live,
        .offline(since: anchor, reason: "Rate limited"),
        .staleCredentials,
        .waitingForClaudeCode,
        .needsAuthorization,
        .noCredentials,
    ]

    @Test("A live meter carries no badge")
    func liveIsUnbadged() {
        #expect(MenuBarStatus.forHealth(.live) == nil)
    }

    /// The whole contract in one assertion: a badge is present exactly when the number beside it
    /// is not live. A state that stopped updating and showed nothing would be the bug this was
    /// added to fix; a badge on a healthy meter would be the noise that teaches people to ignore
    /// it.
    @Test("Every state other than live is badged")
    func everyStoppedStateIsBadged() {
        for state in Self.allStates where state != .live {
            #expect(MenuBarStatus.forHealth(state) != nil, "\(state) went unannounced")
        }
    }

    @Test("Both halves of a badge are always populated")
    func badgesAreComplete() {
        for state in Self.allStates {
            guard let status = MenuBarStatus.forHealth(state) else { continue }
            #expect(status.symbol.isEmpty == false)
            // Read aloud on its own by VoiceOver, so it has to be a sentence rather than a word.
            #expect(status.description.count > 20)
        }
    }

    /// Distinct symbols are the point of having more than one: the states need different actions
    /// from the reader — authorize, run `claude`, sign in, wait — and a shared glyph would make
    /// the badge mean only "something", which the ring already implied by going stale.
    @Test("Each stopped state is distinguishable from the others")
    func statesAreDistinguishable() {
        let badges = Self.allStates.compactMap(MenuBarStatus.forHealth)
        #expect(Set(badges.map(\.symbol)).count == badges.count)
        #expect(Set(badges.map(\.description)).count == badges.count)
    }

    /// The one a click fixes, and the one this was reported for. Pinned by name because the panel
    /// offers an "Authorize" button and a lock is what connects the two.
    @Test("Needing authorization shows a lock")
    func authorizationShowsALock() throws {
        let status = try #require(MenuBarStatus.forHealth(.needsAuthorization))
        #expect(status.symbol.hasPrefix("lock"))
        #expect(status.description.contains("Authorize"))
    }

    /// `offline` carries associated values, and a badge keyed on them rather than on the case
    /// would change every time the reason string did.
    @Test("The offline badge does not vary with its reason or age")
    func offlineBadgeIsStable() {
        let early = MenuBarStatus.forHealth(.offline(since: Self.anchor, reason: "Rate limited"))
        let later = MenuBarStatus.forHealth(
            .offline(since: Self.anchor.addingTimeInterval(9_000), reason: "Timed out"))
        #expect(early == later)
    }
}
