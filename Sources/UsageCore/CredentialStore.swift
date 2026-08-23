import Foundation

// MARK: - Resolved credential

/// Where the token a poll is about to spend came from.
public enum CredentialSource: Sendable, Equatable {
    /// A token the user dedicated to this app, in this app's own Keychain item. The quiet path:
    /// nothing else on the machine writes that item, so nothing ever evicts this app from it and
    /// no dialog can arise.
    case dedicated
    /// Claude Code's shared credential item, read and never written.
    case claudeCode
}

public struct ResolvedCredential: Sendable, Equatable {
    public let credentials: ClaudeCredentials
    public let source: CredentialSource

    public init(credentials: ClaudeCredentials, source: CredentialSource) {
        self.credentials = credentials
        self.source = source
    }
}

/// What the shared item's partition list currently admits, as far as it could be determined.
public struct PartitionState: Sendable, Equatable {
    /// True only when the list was read *and* `apple-tool:` was absent. An unanswered question
    /// is never reported as a lockout.
    public let cliLockedOut: Bool
    /// The one-line repair, when an honest one could be built.
    public let repairCommand: String?

    public static let unknown = PartitionState(cliLockedOut: false, repairCommand: nil)

    public init(cliLockedOut: Bool, repairCommand: String?) {
        self.cliLockedOut = cliLockedOut
        self.repairCommand = repairCommand
    }
}

// MARK: - Store

/// The only place in the app that touches the Security framework.
///
/// An `actor`, and deliberately not `@MainActor`. Every Keychain call is a synchronous IPC to
/// securityd that can take milliseconds on a good day and block indefinitely on a bad one — a
/// legacy-item ACL prompt is modal and waits for a human. Running any of that on the main actor
/// is what made the panel beachball, so none of it happens there any more; the UI awaits a value
/// and stays responsive whatever securityd is doing.
///
/// The second job is thrift. A poll used to decrypt the credential item and copy its ACL every
/// time, several hundred times a day. Here the decrypted credential is held in memory and reused
/// until it either ages out or the item changes underneath us — and "the item changed" is
/// answered by an attributes-only read of the modification date, which decrypts nothing, needs no
/// authorization and cannot raise a dialog. Steady state is therefore zero decrypting reads for
/// as long as a token lives.
public actor CredentialStore {

    // MARK: Tuning

    /// How much life a token must have left to be handed out as-is. Wider than the slowest poll
    /// interval, so a token handed to a request is still valid when that request lands.
    public static let refreshLeadTime: TimeInterval = 5 * 60

    /// A token minted by `claude setup-token` carries no expiry this app can read, so one is
    /// assumed. It is only ever a scheduling hint: the authority on a dead token is a 401, which
    /// clears the stored credential regardless of what this says.
    static let assumedDedicatedLifetime: TimeInterval = 365 * 24 * 3600

    /// The shared item's ACL is re-read no more often than this. It only changes when somebody
    /// writes the item, which is a thing that happens a few times a day, not a few times a
    /// minute.
    static let partitionRecheckInterval: TimeInterval = 10 * 60

    // MARK: State

    private var cached: ResolvedCredential?
    /// The shared item's modification date as of the last decrypting read. When the item's
    /// current date differs, Claude Code has renewed and the cache is stale by definition.
    private var cachedModification: Date?
    /// Set when a non-interactive read was refused, so the app can stop retrying something that
    /// only a user gesture can change, and the panel can offer that gesture.
    private var needsAuthorization = false

    private var partitionCache: (state: PartitionState, readAt: Date)?

    private let refresher: TokenRefresher

    public init(refresher: TokenRefresher = TokenRefresher()) {
        self.refresher = refresher
    }

    // MARK: - Reading

    /// A credential good for a request now, or an error saying what the user has to do.
    ///
    /// Never prompts. `KeychainError.accessDenied` is a legitimate answer, and the caller turns
    /// it into an Authorize button rather than a dialog nobody asked for.
    public func current(now: Date = Date()) throws -> ResolvedCredential {
        // A dedicated token outranks the shared item wherever one exists: it is the path that
        // costs nobody a dialog, so once the user has set one up the shared item is not read at
        // all.
        if let dedicated = try dedicatedCredential(now: now) { return dedicated }

        if let cached, cached.source == .claudeCode, isUsable(cached.credentials, now: now),
            Keychain.modificationDate() == cachedModification
        {
            return cached
        }

        do {
            let stored = try Keychain.readCredentials(interactive: false)
            // Read the modification date *after* the payload. Taken before, a write landing
            // between the two reads would be recorded as already seen, and the app would serve
            // the superseded token until the next expiry rather than the next poll.
            cachedModification = Keychain.modificationDate()
            needsAuthorization = false
            let resolved = ResolvedCredential(credentials: stored, source: .claudeCode)
            cached = resolved
            return resolved
        } catch let error as KeychainError where error.isAuthorizationProblem {
            needsAuthorization = true
            // Evicted, but the token in hand may still have life in it — being locked out of the
            // item says nothing about the validity of what was read from it earlier. Serving the
            // cache is what keeps the meter live across a Claude Code renewal until the token it
            // was holding genuinely ages out.
            if let cached, isUsable(cached.credentials, now: now) { return cached }
            throw error
        }
    }

    /// The same read, permitted to raise the system's authorization dialog. Only ever called
    /// because the user pressed something asking for exactly this.
    @discardableResult
    public func authorize(now: Date = Date()) throws -> ResolvedCredential {
        let stored = try Keychain.readCredentials(interactive: true)
        cachedModification = Keychain.modificationDate()
        needsAuthorization = false
        let resolved = ResolvedCredential(credentials: stored, source: .claudeCode)
        cached = resolved
        return resolved
    }

    /// Whether a read was refused and a user gesture would be worth offering.
    public func isAwaitingAuthorization() -> Bool { needsAuthorization }

    /// Drops the cached credential after the server refused the token it holds. The stored
    /// deadline can be wrong; a 401 cannot, so the next `current` re-reads rather than handing
    /// back the same refused token.
    public func invalidate() {
        cached = nil
        cachedModification = nil
    }

    // MARK: - The dedicated token

    /// This app's own credential, or `nil` when the user has not set one up.
    private func dedicatedCredential(now: Date) throws -> ResolvedCredential? {
        if let cached, cached.source == .dedicated, isUsable(cached.credentials, now: now) {
            return cached
        }
        guard let stored = Keychain.readOwnCredentials() else { return nil }
        let resolved = ResolvedCredential(credentials: stored, source: .dedicated)
        // Cached only while it is actually good for a request. One inside the lead time is about
        // to be renewed, and caching it would hand the same near-dead token back on the next poll
        // as though it were fresh — which is how a credential that needs renewing never gets it.
        if isUsable(stored, now: now) { cached = resolved }
        return resolved
    }

    /// Renews the dedicated credential and stores the result in this app's own item.
    ///
    /// Separated from `dedicatedCredential` because it is `async` and the read path is not — and
    /// because it must never run for a `claudeCode` credential, which this signature makes
    /// impossible to get wrong. Renewing here is safe in a way renewing Claude Code's token never
    /// is: the refresh token being spent is this app's own, the result goes into this app's own
    /// item, and no other process holds a copy to be invalidated or an identity to be evicted.
    ///
    /// `nil` means there was nothing to renew — no dedicated credential, or one with no usable
    /// refresh token, which is the shape `claude setup-token` produces.
    public func renewDedicated(now: Date = Date()) async throws -> ResolvedCredential? {
        guard let stored = Keychain.readOwnCredentials(),
            stored.usableRefreshToken(asOf: now) != nil
        else { return nil }

        let tokens = try await refresher.refresh(stored, now: now)
        let renewed = stored.applying(tokens)
        try Keychain.storeOwnCredentials(renewed)
        let resolved = ResolvedCredential(credentials: renewed, source: .dedicated)
        cached = resolved
        return resolved
    }

    /// Adopts a token the user pasted in, from `claude setup-token`.
    ///
    /// No expiry is known for it, so one is assumed far enough out that it never drives a
    /// refresh; a 401 is what retires it. Nothing here touches Claude Code's item.
    ///
    /// Returns what was actually stored, which is not what was passed in: a token copied out of a
    /// terminal arrives with a trailing newline, and the caller validates by spending it. Handing
    /// back the trimmed credential is what stops the check being made with a different string
    /// from the one saved — that mismatch reads as a refusal and deletes a perfectly good token.
    @discardableResult
    public func adoptDedicatedToken(_ raw: String, now: Date = Date()) throws -> ResolvedCredential
    {
        let token = try Self.normalisedToken(raw)
        let credentials = ClaudeCredentials(
            accessToken: token,
            expiresAt: now.addingTimeInterval(Self.assumedDedicatedLifetime),
            subscriptionType: nil,
            rateLimitTier: nil)
        try Keychain.storeOwnCredentials(credentials)
        let resolved = ResolvedCredential(credentials: credentials, source: .dedicated)
        cached = resolved
        needsAuthorization = false
        return resolved
    }

    /// Exchanges an authorization code and adopts the result as this app's own credential.
    ///
    /// The sibling of `adoptDedicatedToken`, and the better of the two wherever it can be used:
    /// what comes back carries a refresh token, so `CredentialPolicy` takes the `.renew` branch
    /// and the user never has to do this again. A pasted `claude setup-token` token has nothing
    /// to renew with and eventually expires into `.signInRequired`.
    ///
    /// Nothing here touches Claude Code's item — the credential goes into `ownService`, which
    /// this app is the only writer of, so no partition list is reset and nobody is evicted.
    @discardableResult
    public func adoptAuthorizationCode(
        _ code: AuthorizationCode,
        verifier: String,
        redirectURI: String,
        now: Date = Date()
    ) async throws -> ResolvedCredential {
        let tokens = try await refresher.exchange(
            code, verifier: verifier, redirectURI: redirectURI, now: now)
        let credentials = OAuthSignIn.credentials(
            from: tokens, clientID: TokenRefresher.defaultClientID)
        try Keychain.storeOwnCredentials(credentials)
        let resolved = ResolvedCredential(credentials: credentials, source: .dedicated)
        cached = resolved
        needsAuthorization = false
        return resolved
    }

    /// A pasted token as it will actually be stored.
    ///
    /// Split out and made `static` so the rule is testable without a Keychain, because the rule
    /// is what went wrong once: the value stored was trimmed and the value validated was not, so
    /// a token copied out of a terminal — trailing newline and all — was saved, spent as a
    /// different string, refused, and then deleted as though the user had mistyped it. Anything
    /// that needs the storable form asks for it here rather than trimming again at the call site.
    public static func normalisedToken(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw KeychainError.malformed("The token was empty") }
        return token
    }

    /// Forgets the dedicated token and falls back to reading Claude Code's item.
    public func forgetDedicatedToken() {
        Keychain.deleteOwnCredentials()
        if cached?.source == .dedicated { cached = nil }
    }

    public func hasDedicatedToken() -> Bool { Keychain.readOwnCredentials() != nil }

    // MARK: - Partition list

    /// Whether Claude Code can still reach its own item, re-read at most every
    /// `partitionRecheckInterval`.
    ///
    /// This app no longer writes the shared item, so it can no longer *cause* a lockout — but an
    /// earlier build could and did, and a machine carrying that damage needs to be told. Reading
    /// an ACL needs no authorization and decrypts nothing, so this is safe to call from a poll;
    /// the throttle is about securityd round trips, not about safety.
    public func partitionState(now: Date = Date(), force: Bool = false) -> PartitionState {
        if !force, let partitionCache,
            now.timeIntervalSince(partitionCache.readAt) < Self.partitionRecheckInterval
        {
            return partitionCache.state
        }
        let partitions = Keychain.partitionIdentities()
        let locked = Keychain.isCLILockedOut(partitions: partitions)
        let state = PartitionState(
            cliLockedOut: locked, repairCommand: locked ? Keychain.partitionRepairCommand : nil)
        partitionCache = (state, now)
        return state
    }

    // MARK: - Helpers

    private func isUsable(_ credentials: ClaudeCredentials, now: Date) -> Bool {
        !credentials.expiresSoon(asOf: now, lead: Self.refreshLeadTime)
    }
}
