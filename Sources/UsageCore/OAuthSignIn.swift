import CryptoKit
import Foundation

// MARK: - PKCE

/// A proof key for one sign-in: a random secret and the digest the browser carries in its place.
///
/// The verifier never leaves this process until the code has already come back, so a party that
/// intercepts the redirect still cannot complete the exchange. That is the whole reason a public
/// client — one with no secret to prove itself with, which is what every desktop app is — can run
/// this flow safely at all.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    /// A fresh pair. 32 random bytes is the middle of the range RFC 7636 allows, and base64url
    /// makes it 43 characters — the shortest legal verifier, which is also the least to go wrong
    /// in a URL.
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        // The failure branch is not reachable in practice, and a verifier built from a failed
        // draw would be 32 zero bytes — a fixed secret, which is no secret. `SecRandom` is the
        // only source here for that reason; there is no fallback because a fallback would be
        // worse than the crash.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    /// A pair around a verifier chosen by the caller. Exists so the digest can be checked
    /// against a published vector rather than against itself.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without padding, per RFC 7636 §4.1: `+` and `/` would need escaping in a query
    /// and `=` is not permitted in a verifier at all.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - The code

/// An authorization code as it came back, with the state that accompanied it.
public struct AuthorizationCode: Sendable, Equatable {
    public let code: String
    /// Absent when the code arrived by a route that echoed no state.
    public let state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

// MARK: - Errors

public enum OAuthSignInError: Error, Sendable, Equatable {
    /// Nothing usable in what was pasted.
    case emptyCode
    /// The request that arrived on the loopback port was not the callback.
    case notTheCallback
    /// The callback arrived, but carried no code — usually alongside an `error`.
    case noCode
    /// The authorization server said no. The payload is its `error` code.
    case denied(String)
    /// The code came back under a different state from the one this app sent.
    case stateMismatch
    /// No loopback port could be opened, so the browser has nowhere to return to.
    case noLoopbackPort
    /// The browser never came back within the window the app waited.
    case timedOut
    /// The user closed the sign-in before it finished.
    case cancelled
}

extension OAuthSignInError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "No authorization code was entered."
        case .notTheCallback, .noCode:
            return "The browser came back without an authorization code."
        case .denied(let error):
            return error == "access_denied"
                ? "Authorization was declined in the browser."
                : "The authorization server refused the request: \(error)."
        case .stateMismatch:
            return "The browser came back under a different request. Try signing in again."
        case .noLoopbackPort:
            return "ClaudeMeter could not open a local port for the browser to return to."
        case .timedOut:
            return "The browser did not come back in time. Try signing in again."
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}

// MARK: - The flow

/// The authorization-code half of Claude Code's OAuth flow, so this app can mint a credential of
/// its own without the user going to a terminal for `claude setup-token`.
///
/// Every constant here was read out of the shipped CLI rather than guessed, and the token
/// endpoint is the one `TokenRefresher` already posts to — a credential this produces is the same
/// shape the CLI's own login produces, which is what makes `CredentialStore` able to renew it
/// with no special case.
///
/// What it buys over the pasted-token path it sits beside: the exchange returns a *refresh*
/// token. A `claude setup-token` token has none, so it eventually expires into
/// `.signInRequired` and has to be pasted again; this one renews itself for as long as the grant
/// stands. And because the result lands in this app's own Keychain item, nothing evicts anybody:
/// Claude Code's item is never read, so no partition list is ever reset and no dialog is ever
/// raised.
public enum OAuthSignIn {
    /// Claude Code's production authorization endpoint — the *subscription* one.
    ///
    /// The CLI carries two and chooses between them (`loginWithClaudeAi ? CLAUDE_AI_AUTHORIZE_URL
    /// : CONSOLE_AUTHORIZE_URL`), and the choice is not cosmetic: they mint tokens against
    /// different things. `platform.claude.com/oauth/authorize` is the Console route, for API
    /// billing; this one is the Claude subscription route, for a Pro or Max plan.
    ///
    /// It has to be this one, because `/api/oauth/usage` reports the rate limits of a
    /// *subscription*. A token minted through Console has no subscription behind it, so the
    /// endpoint answers 401 — which it did, twice, while the fault was mistaken for a scope that
    /// was too narrow. The sign-in and the exchange both succeed either way, so nothing goes
    /// wrong until the very last step, which is what made it look like a permissions problem.
    public static let authorizeEndpoint = URL(
        string: "https://claude.com/cai/oauth/authorize")!

    /// Where the server sends the code when there is no loopback listener: a page that displays
    /// the code as `code#state` for the user to copy. The fallback, not the first choice.
    ///
    /// Stays on `platform.claude.com` even though the authorization does not: the CLI picks the
    /// redirect from whether the flow is manual, not from which authorize endpoint it used.
    public static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"

    /// What this app asks to be allowed to do.
    ///
    /// The CLI's own login set with `org:create_api_key` removed: the credential Claude Code
    /// writes — the one observed polling `/api/oauth/usage` successfully on this machine —
    /// carries exactly these five and not that sixth, so a token minted with them is known to be
    /// accepted, and a meter has no business minting API keys.
    ///
    /// Not the cause of the 401s that preceded this, despite two attempts to fix it here. Those
    /// were the Console authorize endpoint minting a token with no subscription behind it; see
    /// `authorizeEndpoint`. The set is kept matched to a credential known to work anyway, because
    /// the alternative is guessing which of the five the endpoint gates.
    public static let scopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]

    /// The redirect for a browser that can come straight back to this process.
    public static func loopbackRedirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }

    /// Where to send the browser.
    public static func authorizationURL(
        challenge: String,
        state: String,
        redirectURI: String,
        clientID: String = TokenRefresher.defaultClientID
    ) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // The CLI sends this, and the page behaves differently without it: it is what asks
            // for a code to be displayed rather than an implicit grant.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// A random value tying the code that comes back to the request that went out.
    public static func makeState() -> String { PKCEPair().verifier }

    // MARK: Reading the code back

    /// What the callback page shows, as the user pasted it.
    ///
    /// The page displays `code#state`, and people copy the whole thing — so the halves are split
    /// here rather than sent to the token endpoint as one string, which is refused. Trimming
    /// matters for the same reason it does in `CredentialStore.normalisedToken`: a value copied
    /// out of a browser arrives with whitespace far more often than not.
    public static func parsePastedCode(_ raw: String) throws -> AuthorizationCode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthSignInError.emptyCode }

        let halves = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(halves[0])
        guard !code.isEmpty else { throw OAuthSignInError.emptyCode }
        let state = halves.count > 1 ? String(halves[1]) : nil
        return AuthorizationCode(code: code, state: state?.isEmpty == true ? nil : state)
    }

    /// The code carried by a request that arrived on the loopback port.
    ///
    /// `requestTarget` is the middle field of the HTTP request line — `/callback?code=…`. Split
    /// out from the listener so the parsing is testable without opening a socket, which is the
    /// only part of the loopback path where anything can be got wrong.
    public static func parseCallback(requestTarget: String) throws -> AuthorizationCode {
        // A relative target needs a base to parse against; the host is immaterial, since only
        // the path and query are read back out.
        guard let components = URLComponents(string: "http://localhost" + requestTarget),
            components.path == "/callback"
        else {
            // Browsers ask for `/favicon.ico` on their way past. Treating that as a failed
            // callback would abandon a sign-in the user is still completing.
            throw OAuthSignInError.notTheCallback
        }

        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })

        if let error = items["error"], !error.isEmpty { throw OAuthSignInError.denied(error) }
        guard let code = items["code"], !code.isEmpty else { throw OAuthSignInError.noCode }
        let state = items["state"]
        return AuthorizationCode(code: code, state: state?.isEmpty == true ? nil : state)
    }

    /// The request target — `/callback?code=…` — out of the first line of an HTTP request.
    ///
    /// Here rather than beside the socket that read the bytes, because this is the part with
    /// decisions in it: anything that is not a `GET` request line is not something to answer, and
    /// a listener that guessed would hand `parseCallback` a string it never saw on the wire.
    public static func requestTarget(inRequest data: Data) -> String? {
        // A request line is ASCII by definition, and a percent-encoded query keeps it that way,
        // so anything undecodable is not a request line worth reading.
        guard let text = String(data: data, encoding: .utf8),
            let line = text.split(separator: "\r\n", maxSplits: 1).first
        else { return nil }

        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }
        return String(fields[1])
    }

    /// Checks the code came back under the state that went out.
    ///
    /// A code with no state at all passes: the manual page does not always echo one, and
    /// refusing on that basis would fail a sign-in that is otherwise perfectly good. The check
    /// is worth having anyway, because the loopback route always carries one and that is the
    /// route a stray request could arrive on.
    public static func validate(_ code: AuthorizationCode, expecting state: String) throws {
        guard let received = code.state else { return }
        guard received == state else { throw OAuthSignInError.stateMismatch }
    }

    // MARK: Exchanging it

    /// The token request body, in the shape the CLI sends.
    public static func exchangeBody(
        _ code: AuthorizationCode,
        verifier: String,
        redirectURI: String,
        clientID: String = TokenRefresher.defaultClientID
    ) throws -> Data {
        var body = [
            "grant_type": "authorization_code",
            "code": code.code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        if let state = code.state { body["state"] = state }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The exchanged pair as a credential this app can store and renew.
    ///
    /// The plan and tier fields the CLI writes are not in the token response, so they stay nil;
    /// nothing on the polling path reads them for a dedicated credential.
    public static func credentials(
        from tokens: RefreshedTokens, clientID: String?
    ) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: tokens.accessToken,
            expiresAt: tokens.expiresAt,
            // Empty is how `decodeTokens` reports "the response carried none", since there was
            // no prior token to carry forward. `usableRefreshToken` already reads an empty
            // string as nothing to renew with, but storing nil says so plainly.
            refreshToken: tokens.refreshToken.isEmpty ? nil : tokens.refreshToken,
            refreshTokenExpiresAt: tokens.refreshTokenExpiresAt,
            scopes: tokens.scopes,
            clientID: clientID,
            subscriptionType: nil,
            rateLimitTier: nil)
    }
}
