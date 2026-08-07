import Foundation

// MARK: - Refreshed tokens

/// A renewed token pair, as the OAuth endpoint returned it.
public struct RefreshedTokens: Sendable, Equatable {
    public let accessToken: String
    /// The server may rotate the refresh token or hand the same one back; when the
    /// response omits it, the token used for the refresh is carried forward, which is
    /// what Claude Code does with the same response.
    public let refreshToken: String
    public let expiresAt: Date
    /// Nil when the response said nothing about the refresh token's own deadline.
    public let refreshTokenExpiresAt: Date?
    /// Empty when the response echoed no scopes, in which case the stored ones stand.
    public let scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        refreshTokenExpiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
    }
}

extension ClaudeCredentials {
    /// The stored credentials with a refreshed pair folded in. Fields the token endpoint does
    /// not speak to — the plan and tier the CLI wrote, the client the tokens belong to — are
    /// carried across unchanged, and omitted scopes or refresh deadlines keep their old values
    /// rather than being cleared.
    public func applying(_ tokens: RefreshedTokens) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: tokens.accessToken,
            expiresAt: tokens.expiresAt,
            refreshToken: tokens.refreshToken,
            refreshTokenExpiresAt: tokens.refreshTokenExpiresAt ?? refreshTokenExpiresAt,
            scopes: tokens.scopes.isEmpty ? scopes : tokens.scopes,
            clientID: clientID,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }
}

// MARK: - Errors

/// Why a refresh did not produce a new token.
///
/// The split that matters is `.rejected` against everything else: a rejected grant is
/// permanent and the user has to sign in again, while a transport failure or a 500 is
/// worth retrying on the next poll.
public enum TokenRefreshError: Error, Sendable, Equatable {
    /// No refresh token stored, or its own deadline has passed. Signing in is the only fix.
    case noRefreshToken
    /// The server refused the grant — revoked, already rotated away, or expired server-side.
    case rejected(String)
    case httpStatus(Int)
    case transport(String)
    case decoding(String)

    /// True when retrying with the same refresh token cannot work.
    public var requiresSignIn: Bool {
        switch self {
        case .noRefreshToken, .rejected:
            return true
        case .httpStatus, .transport, .decoding:
            return false
        }
    }
}

extension TokenRefreshError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noRefreshToken:
            return "No refresh token — sign in to Claude Code again"
        case .rejected(let detail):
            return "Refresh refused — \(detail)"
        case .httpStatus(let code):
            return "Token refresh failed — HTTP \(code)"
        case .transport(let message):
            return message
        case .decoding(let message):
            return "Unexpected refresh response: \(message)"
        }
    }
}

// MARK: - Client

/// Trades a refresh token for a fresh access token on Claude Code's OAuth endpoint.
///
/// The endpoint, the client identifier and the JSON request shape are the CLI's own —
/// this is the same exchange `claude` performs when its token ages out, so a token this
/// app renews is one the CLI accepts, and vice versa. Nothing here writes: persisting is
/// `Keychain.storeRefreshedTokens`, which is conditional on the CLI not having refreshed
/// first.
public struct TokenRefresher: Sendable {
    /// Claude Code's token endpoint, read out of the shipped CLI rather than guessed.
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client. Used when the stored credentials name no client
    /// of their own, which is the shape older CLI versions wrote.
    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One refresh attempt. `now` anchors the returned deadline, since the server reports
    /// a lifetime in seconds rather than an absolute time.
    public func refresh(
        _ credentials: ClaudeCredentials, now: Date = Date()
    ) async throws -> RefreshedTokens {
        guard let refreshToken = credentials.usableRefreshToken(asOf: now) else {
            throw TokenRefreshError.noRefreshToken
        }

        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID ?? Self.defaultClientID,
        ]
        // Asking for the scopes already held: a refresh that omitted them could come back
        // narrower than the token it replaced, and the usage endpoint would start refusing.
        if !credentials.scopes.isEmpty {
            body["scope"] = credentials.scopes.joined(separator: " ")
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw TokenRefreshError.decoding("Refresh request could not be encoded")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TokenRefreshError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TokenRefreshError.transport("Response was not HTTP")
        }

        guard (200...299).contains(http.statusCode) else {
            // 400 and 401 are how this endpoint says the grant itself is no good —
            // `invalid_grant` for a refresh token that has been revoked or rotated away.
            // Everything else is the server having a bad day and worth another try.
            if http.statusCode == 400 || http.statusCode == 401 {
                throw TokenRefreshError.rejected(Self.errorDetail(from: data, status: http.statusCode))
            }
            throw TokenRefreshError.httpStatus(http.statusCode)
        }

        return try Self.decodeTokens(from: data, refreshedWith: refreshToken, now: now)
    }

    /// Pure decode, exposed so tests cover the wire shape with no network.
    public static func decodeTokens(
        from data: Data, refreshedWith refreshToken: String, now: Date
    ) throws -> RefreshedTokens {
        let payload: TokenPayload
        do {
            payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        } catch {
            throw TokenRefreshError.decoding(String(describing: error))
        }
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw TokenRefreshError.decoding("Response carried no `access_token`")
        }
        guard let lifetime = payload.expiresIn, lifetime.isFinite, lifetime > 0 else {
            // Without a lifetime there is no way to know when to refresh next, and
            // assuming one would either re-refresh every poll or ride a dead token.
            throw TokenRefreshError.decoding("Response carried no usable `expires_in`")
        }

        return RefreshedTokens(
            accessToken: accessToken,
            // A response with no `refresh_token` means "keep using the one you sent".
            refreshToken: payload.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken,
            expiresAt: now.addingTimeInterval(min(lifetime, Self.maximumLifetime)),
            refreshTokenExpiresAt: payload.refreshTokenExpiresIn
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                .map { now.addingTimeInterval(min($0, Self.maximumLifetime)) },
            scopes: payload.scope?.split(separator: " ").map(String.init) ?? []
        )
    }

    /// A lifetime is turned into a `Date`, and a non-finite or absurd one would produce a
    /// deadline that never arrives — so a token that "never expires" is capped at a year
    /// and simply refreshes again when it gets there.
    private static let maximumLifetime: TimeInterval = 365 * 24 * 3600

    /// The `error_description` if the server sent one, falling back to `error`, then to the
    /// status code. Only ever used as display text.
    private static func errorDetail(from data: Data, status: Int) -> String {
        guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
            return "HTTP \(status)"
        }
        if let description = payload.errorDescription, !description.isEmpty { return description }
        if let error = payload.error, !error.isEmpty { return error }
        return "HTTP \(status)"
    }
}

// MARK: - Wire DTOs

/// The token endpoint's response. Every field is optional so an added key cannot make the
/// whole response unreadable; the two that must be present are checked after decoding.
private struct TokenPayload: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let refreshTokenExpiresIn: TimeInterval?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try? container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try? container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn)
        refreshTokenExpiresIn = try? container.decodeIfPresent(
            TimeInterval.self, forKey: .refreshTokenExpiresIn)
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
    }
}

private struct ErrorPayload: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        errorDescription = try? container.decodeIfPresent(String.self, forKey: .errorDescription)
    }
}
