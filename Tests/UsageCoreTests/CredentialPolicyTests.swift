import Foundation
import Testing

import UsageCore

// Pure decisions about a credential. No Keychain, no network.
//
// The axis these turn on is no longer a setting but the *source*: Claude Code's credential is
// never renewed here, because spending its refresh token retires the copy the CLI is holding and
// the only way to hand the replacement over — writing the shared item — locks the CLI out of it.
// A credential the user dedicated to this app has neither problem and is renewed freely.

private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
private let lead: TimeInterval = 5 * 60

private func credentials(
    expiringAt expiry: Date,
    refreshToken: String? = "r",
    refreshTokenExpiresAt: Date? = nil
) -> ClaudeCredentials {
    ClaudeCredentials(
        accessToken: "t",
        expiresAt: expiry,
        refreshToken: refreshToken,
        refreshTokenExpiresAt: refreshTokenExpiresAt,
        subscriptionType: nil,
        rateLimitTier: nil)
}

private func decide(
    _ credentials: ClaudeCredentials, from source: CredentialSource
) -> CredentialPolicy.Renewal {
    CredentialPolicy.decide(
        ResolvedCredential(credentials: credentials, source: source), now: anchor, lead: lead)
}

private func afterRejection(
    _ credentials: ClaudeCredentials, from source: CredentialSource
) -> CredentialPolicy.Renewal {
    CredentialPolicy.decideAfterRejection(
        ResolvedCredential(credentials: credentials, source: source), now: anchor)
}

@Suite("Credential renewal policy")
struct CredentialPolicyTests {
    @Test("A token with hours left is used as it stands, whatever its source")
    func freshTokenIsLeftAlone() {
        let fresh = credentials(expiringAt: anchor.addingTimeInterval(3600))
        #expect(decide(fresh, from: .claudeCode) == .useStored)
        #expect(decide(fresh, from: .dedicated) == .useStored)
    }

    /// Claude Code's near-expiry token is not merely left unrenewed, it is still used: there are
    /// minutes of life left in it and a request started now lands inside them.
    @Test("A token near expiry is renewed only when this app owns it")
    func nearExpiryFollowsTheSource() {
        let near = credentials(expiringAt: anchor.addingTimeInterval(60))
        #expect(decide(near, from: .claudeCode) == .useStored)
        #expect(decide(near, from: .dedicated) == .renew)
    }

    @Test("An expired token of Claude Code's waits for Claude Code")
    func expiredWaitsForTheOwner() {
        let dead = credentials(expiringAt: anchor.addingTimeInterval(-3600))
        #expect(decide(dead, from: .claudeCode) == .waitForClaudeCode)
        #expect(decide(dead, from: .dedicated) == .renew)
    }

    /// Waiting for the CLI only makes sense if the CLI has something to renew with. A credential
    /// nobody can renew has to say so, or the panel parks on "waiting" forever while its numbers
    /// age — which is worse than the sign-in prompt it replaced.
    @Test("An expired token that nobody can renew asks for a sign-in, not for patience")
    func expiredAndUnrenewable() {
        let noToken = credentials(expiringAt: anchor.addingTimeInterval(-60), refreshToken: nil)
        let emptyToken = credentials(expiringAt: anchor.addingTimeInterval(-60), refreshToken: "")
        let deadRefresh = credentials(
            expiringAt: anchor.addingTimeInterval(-60),
            refreshTokenExpiresAt: anchor.addingTimeInterval(-1))
        for dead in [noToken, emptyToken, deadRefresh] {
            #expect(decide(dead, from: .claudeCode) == .signInRequired)
            #expect(decide(dead, from: .dedicated) == .signInRequired)
        }
    }

    @Test("The lead time is inclusive at its own boundary")
    func leadBoundaryIsInclusive() {
        let atBoundary = credentials(expiringAt: anchor.addingTimeInterval(lead))
        let justOutside = credentials(expiringAt: anchor.addingTimeInterval(lead + 1))
        #expect(decide(atBoundary, from: .dedicated) == .renew)
        #expect(decide(justOutside, from: .dedicated) == .useStored)
    }

    /// The window between the two predicates is what separates "poll with what we have" from
    /// "there is nothing left to poll with", so they have to disagree inside it.
    @Test("Expiring soon and expired are different questions inside the lead time")
    func soonAndExpiredDiverge() {
        let near = credentials(expiringAt: anchor.addingTimeInterval(60))
        #expect(near.expiresSoon(asOf: anchor, lead: lead))
        #expect(near.isExpired(asOf: anchor) == false)
    }

    /// A 401 is the one signal that outranks the stored deadline, so the deadline is not
    /// consulted — but whose credential it is still is. Without this the rule would hold only
    /// until the first refusal, which is exactly the moment a meter riding its tokens to expiry
    /// reaches.
    @Test("A refused token of Claude Code's is still never renewed here")
    func rejectionFollowsTheSource() {
        let live = credentials(expiringAt: anchor.addingTimeInterval(3600))
        #expect(afterRejection(live, from: .claudeCode) == .waitForClaudeCode)
        #expect(afterRejection(live, from: .dedicated) == .renew)
    }

    @Test("A refused token with nothing to renew it asks for a sign-in either way")
    func rejectionWithoutRefreshToken() {
        let orphan = credentials(expiringAt: anchor.addingTimeInterval(3600), refreshToken: nil)
        #expect(afterRejection(orphan, from: .claudeCode) == .signInRequired)
        #expect(afterRejection(orphan, from: .dedicated) == .signInRequired)
    }

    /// The rule the whole redesign rests on: there is no argument, no setting and no source that
    /// makes `.renew` the answer for Claude Code's own credential.
    @Test("Claude Code's credential is never renewed by this app, in any state")
    func claudeCodeIsNeverRenewed() {
        let offsets: [TimeInterval] = [-86_400, -3600, -1, 0, 1, 60, lead, lead + 1, 3600]
        for offset in offsets {
            let credential = credentials(expiringAt: anchor.addingTimeInterval(offset))
            #expect(decide(credential, from: .claudeCode) != .renew)
            #expect(afterRejection(credential, from: .claudeCode) != .renew)
        }
    }
}
