import Foundation

/// What a poll should do with the credential it is holding.
///
/// The rule this encodes is short, and it used to be long. It used to weigh whether renewing
/// Claude Code's token was worth resetting the shared Keychain item's partition list; the answer
/// is now known to be "never", so the weighing is gone (see `Keychain` for the measurement that
/// settled it). What is left is the part that was always true: a credential is either good for a
/// request, or it is not, and when it is not the fix depends on whose credential it is.
///
/// A credential this app owns — one the user dedicated to it — may be renewed freely, because
/// nobody else holds a copy to be invalidated and nobody else's access is reset by the write.
/// Claude Code's may not be renewed at all.
///
/// Pure and parameterised, so the decision is tested without a Keychain, a network or an
/// `AppModel`.
public enum CredentialPolicy {

    /// What to do with the credential a poll is holding.
    public enum Renewal: Equatable, Sendable {
        /// Good for a request exactly as it stands.
        case useStored
        /// Near expiry, and this app owns the credential, so it may renew it itself.
        case renew
        /// Aged out, and it belongs to Claude Code. The CLI renews on its own schedule and the
        /// next poll picks the result up.
        case waitForClaudeCode
        /// Beyond renewal by anybody: no refresh token, or one that has expired in its own right.
        /// Only the user supplying a new credential clears it.
        case signInRequired
    }

    /// The decision for a credential whose own deadline is the only evidence available.
    public static func decide(
        _ credential: ResolvedCredential,
        now: Date,
        lead: TimeInterval
    ) -> Renewal {
        guard credential.credentials.expiresSoon(asOf: now, lead: lead) else { return .useStored }

        switch credential.source {
        case .claudeCode:
            // Inside the lead time but not past it, the stored token still serves this request,
            // and leaving it alone is the whole point: this app does not renew what it does not
            // own, so there is nothing to gain by acting early.
            guard credential.credentials.isExpired(asOf: now) else { return .useStored }
            // Waiting only makes sense if there is something for Claude Code to renew *with*. A
            // credential minted by `claude setup-token`, or one whose refresh token has itself
            // expired, will never come back on its own, and telling the user to run `claude` and
            // wait would park the panel on a snapshot that ages forever.
            return credential.credentials.usableRefreshToken(asOf: now) != nil
                ? .waitForClaudeCode : .signInRequired
        case .dedicated:
            return credential.credentials.usableRefreshToken(asOf: now) != nil
                ? .renew : .signInRequired
        }
    }

    /// The same decision for a token the server has just refused.
    ///
    /// A 401 outranks the stored deadline — the deadline can be wrong, the refusal cannot — so
    /// there is no freshness test here. A dedicated token that cannot be renewed is spent, and
    /// the user has to supply another; Claude Code's is left for Claude Code, as always.
    public static func decideAfterRejection(
        _ credential: ResolvedCredential,
        now: Date
    ) -> Renewal {
        guard credential.credentials.usableRefreshToken(asOf: now) != nil else {
            return .signInRequired
        }
        return credential.source == .dedicated ? .renew : .waitForClaudeCode
    }
}
