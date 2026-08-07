import Foundation
import Testing

import UsageCore

// These tests never make a request. Everything goes through `decodeTokens`, the pure
// half of `TokenRefresher`, so no network or Keychain access is involved.

private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

private func decode(_ json: String, refreshedWith token: String = "old-refresh") throws
    -> RefreshedTokens
{
    try TokenRefresher.decodeTokens(from: Data(json.utf8), refreshedWith: token, now: anchor)
}

private func failure(decoding json: String) -> TokenRefreshError? {
    do {
        _ = try decode(json)
        return nil
    } catch let error as TokenRefreshError {
        return error
    } catch {
        return nil
    }
}

private func isDecoding(_ error: TokenRefreshError?) -> Bool {
    guard let error else { return false }
    if case .decoding = error { return true }
    return false
}

private let fullResponseJSON = """
{
  "access_token": "sk-ant-oat01-NEW",
  "refresh_token": "sk-ant-ort01-NEW",
  "expires_in": 28800,
  "refresh_token_expires_in": 1728000,
  "scope": "user:inference user:profile"
}
"""

@Suite("OAuth token refresh")
struct TokenRefresherTests {
    @Test("Endpoint and client identifier match what the CLI uses")
    func endpointMatchesCLI() {
        #expect(
            TokenRefresher.endpoint.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(TokenRefresher.defaultClientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test("Parses the full response shape")
    func parsesFullShape() throws {
        let tokens = try decode(fullResponseJSON)
        #expect(tokens.accessToken == "sk-ant-oat01-NEW")
        #expect(tokens.refreshToken == "sk-ant-ort01-NEW")
        #expect(tokens.scopes == ["user:inference", "user:profile"])
    }

    @Test("expires_in is a lifetime in seconds, measured from now")
    func lifetimeIsRelative() throws {
        let tokens = try decode(fullResponseJSON)
        #expect(tokens.expiresAt == anchor.addingTimeInterval(28_800))
        #expect(tokens.refreshTokenExpiresAt == anchor.addingTimeInterval(1_728_000))
    }

    @Test("A response with no refresh_token carries the old one forward")
    func refreshTokenCarriedForward() throws {
        let json = #"{"access_token": "new", "expires_in": 3600}"#
        let tokens = try decode(json, refreshedWith: "still-good")
        #expect(tokens.refreshToken == "still-good")
    }

    @Test("An empty refresh_token is treated as absent, not as a wipe")
    func emptyRefreshTokenCarriedForward() throws {
        let json = #"{"access_token": "new", "refresh_token": "", "expires_in": 3600}"#
        let tokens = try decode(json, refreshedWith: "still-good")
        #expect(tokens.refreshToken == "still-good")
    }

    @Test("An omitted refresh_token_expires_in leaves the deadline unstated")
    func refreshDeadlineOptional() throws {
        let json = #"{"access_token": "new", "expires_in": 3600}"#
        #expect(try decode(json).refreshTokenExpiresAt == nil)
        #expect(try decode(json).scopes.isEmpty)
    }

    @Test("Missing or unusable expires_in fails rather than inventing a deadline")
    func lifetimeRequired() {
        #expect(isDecoding(failure(decoding: #"{"access_token": "new"}"#)))
        #expect(isDecoding(failure(decoding: #"{"access_token": "new", "expires_in": 0}"#)))
        #expect(isDecoding(failure(decoding: #"{"access_token": "new", "expires_in": -5}"#)))
    }

    @Test("Missing or empty access_token fails")
    func accessTokenRequired() {
        #expect(isDecoding(failure(decoding: #"{"expires_in": 3600}"#)))
        #expect(isDecoding(failure(decoding: #"{"access_token": "", "expires_in": 3600}"#)))
    }

    @Test("Garbage payloads throw .decoding, never crash")
    func garbagePayloads() {
        #expect(isDecoding(failure(decoding: "not json at all {{{")))
        #expect(isDecoding(failure(decoding: "")))
        #expect(isDecoding(failure(decoding: "[]")))
    }

    @Test("An absurd lifetime is capped rather than becoming a deadline that never arrives")
    func lifetimeCapped() throws {
        let json = #"{"access_token": "new", "expires_in": 1e30}"#
        let tokens = try decode(json)
        #expect(tokens.expiresAt.timeIntervalSince(anchor) <= 366 * 24 * 3600)
        #expect(tokens.expiresAt > anchor)
    }

    @Test("A non-finite lifetime is not a usable deadline")
    func nonFiniteLifetime() {
        // `TimeInterval("nan")` and `"inf"` both parse in Swift, so a server sending either
        // must not produce a `Date` that comparisons then answer `false` to forever.
        #expect(isDecoding(failure(decoding: #"{"access_token": "n", "expires_in": "nan"}"#)))
        #expect(isDecoding(failure(decoding: #"{"access_token": "n", "expires_in": "inf"}"#)))
    }

    @Test("Only a refused grant asks for a new sign-in")
    func signInClassification() {
        #expect(TokenRefreshError.noRefreshToken.requiresSignIn)
        #expect(TokenRefreshError.rejected("invalid_grant").requiresSignIn)
        #expect(TokenRefreshError.httpStatus(500).requiresSignIn == false)
        #expect(TokenRefreshError.transport("offline").requiresSignIn == false)
        #expect(TokenRefreshError.decoding("nonsense").requiresSignIn == false)
    }
}

// MARK: - Request shape

/// Answers every request from memory, so no test in this file opens a socket.
private final class RefreshStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var recordedRequest: URLRequest?
    nonisolated(unsafe) private static var recordedBody: Data?

    static func set(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        Self.status = status
        Self.body = body
        recordedRequest = nil
        recordedBody = nil
    }

    static func lastRequest() -> (request: URLRequest, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard let recordedRequest else { return nil }
        return (recordedRequest, recordedBody ?? Data())
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLSession` moves `httpBody` onto `httpBodyStream` before the protocol sees the
        // request, so reading `httpBody` alone would record an empty body for every request.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            body = collected
        }

        Self.lock.lock()
        Self.recordedRequest = request
        Self.recordedBody = body
        let status = Self.status
        let payload = Self.body
        Self.lock.unlock()

        guard let client else { return }
        if let response = HTTPURLResponse(
            url: request.url ?? TokenRefresher.endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:])
        {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocol(self, didLoad: payload)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized because these share one `URLProtocol` stub; nothing here opens a socket or
/// touches the Keychain.
@Suite(.serialized)
struct TokenRefreshRequestTests {
    private typealias Stub = RefreshStubURLProtocol

    private let credentials = ClaudeCredentials(
        accessToken: "old-access",
        expiresAt: anchor,
        refreshToken: "old-refresh",
        scopes: ["user:inference", "user:profile"],
        clientID: nil,
        subscriptionType: nil,
        rateLimitTier: nil
    )

    private func sentBody(after refresh: () async throws -> Void) async rethrows -> [String: Any] {
        try await refresh()
        guard let (_, body) = Stub.lastRequest(),
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return json
    }

    @Test("The refresh posts JSON to the CLI's token endpoint")
    func requestShape() async throws {
        Stub.set(status: 200, body: Data(fullResponseJSON.utf8))
        _ = try await TokenRefresher(session: Stub.session()).refresh(credentials, now: anchor)

        let (request, _) = try #require(Stub.lastRequest())
        #expect(request.url == TokenRefresher.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("The body carries the grant, the token and the client")
    func requestBody() async throws {
        Stub.set(status: 200, body: Data(fullResponseJSON.utf8))
        let body = try await sentBody {
            _ = try await TokenRefresher(session: Stub.session()).refresh(credentials, now: anchor)
        }
        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["refresh_token"] as? String == "old-refresh")
        // No client stored, so the CLI's own public client stands in.
        #expect(body["client_id"] as? String == TokenRefresher.defaultClientID)
        // Scopes are re-requested so a renewed token is not narrower than the one it replaces.
        #expect(body["scope"] as? String == "user:inference user:profile")
    }

    @Test("A stored client identifier is used in preference to the default")
    func storedClientIdentifier() async throws {
        let scoped = ClaudeCredentials(
            accessToken: "a", expiresAt: anchor, refreshToken: "r",
            clientID: "client-abc", subscriptionType: nil, rateLimitTier: nil)
        Stub.set(status: 200, body: Data(fullResponseJSON.utf8))
        let body = try await sentBody {
            _ = try await TokenRefresher(session: Stub.session()).refresh(scoped, now: anchor)
        }
        #expect(body["client_id"] as? String == "client-abc")
        // Nothing stored to re-request, so the server is left to apply its own default.
        #expect(body["scope"] == nil)
    }

    @Test("A refused grant is permanent; a server error is not")
    func statusClassification() async throws {
        let refusal = Data(#"{"error": "invalid_grant", "error_description": "revoked"}"#.utf8)
        for status in [400, 401] {
            Stub.set(status: status, body: refusal)
            await #expect(throws: TokenRefreshError.rejected("revoked")) {
                _ = try await TokenRefresher(session: Stub.session())
                    .refresh(credentials, now: anchor)
            }
        }

        Stub.set(status: 503, body: Data())
        await #expect(throws: TokenRefreshError.httpStatus(503)) {
            _ = try await TokenRefresher(session: Stub.session()).refresh(credentials, now: anchor)
        }
    }

    @Test("A refusal with no readable body still reports the status")
    func refusalWithoutBody() async throws {
        Stub.set(status: 400, body: Data("not json".utf8))
        await #expect(throws: TokenRefreshError.rejected("HTTP 400")) {
            _ = try await TokenRefresher(session: Stub.session()).refresh(credentials, now: anchor)
        }
    }

    @Test("No usable refresh token means no request is made at all")
    func noRequestWithoutRefreshToken() async throws {
        Stub.set(status: 200, body: Data(fullResponseJSON.utf8))
        let bare = ClaudeCredentials(
            accessToken: "a", expiresAt: anchor, subscriptionType: nil, rateLimitTier: nil)
        await #expect(throws: TokenRefreshError.noRefreshToken) {
            _ = try await TokenRefresher(session: Stub.session()).refresh(bare, now: anchor)
        }
        #expect(Stub.lastRequest() == nil)
    }
}

@Suite("Folding a refresh into stored credentials")
struct CredentialMergeTests {
    private let stored = ClaudeCredentials(
        accessToken: "old-access",
        expiresAt: anchor,
        refreshToken: "old-refresh",
        refreshTokenExpiresAt: anchor.addingTimeInterval(86_400),
        scopes: ["user:inference"],
        clientID: "client-abc",
        subscriptionType: "max",
        rateLimitTier: "default"
    )

    @Test("The refreshed pair replaces the tokens and nothing else")
    func replacesTokensOnly() {
        let tokens = RefreshedTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: anchor.addingTimeInterval(3600)
        )
        let merged = stored.applying(tokens)
        #expect(merged.accessToken == "new-access")
        #expect(merged.refreshToken == "new-refresh")
        #expect(merged.expiresAt == anchor.addingTimeInterval(3600))
        // Fields the token endpoint says nothing about survive the trip.
        #expect(merged.clientID == "client-abc")
        #expect(merged.subscriptionType == "max")
        #expect(merged.rateLimitTier == "default")
    }

    @Test("Unstated scopes and refresh deadline keep their stored values")
    func omittedFieldsPreserved() {
        let tokens = RefreshedTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: anchor.addingTimeInterval(3600)
        )
        let merged = stored.applying(tokens)
        #expect(merged.scopes == ["user:inference"])
        #expect(merged.refreshTokenExpiresAt == anchor.addingTimeInterval(86_400))
    }

    @Test("Stated scopes and refresh deadline win")
    func statedFieldsReplace() {
        let tokens = RefreshedTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: anchor.addingTimeInterval(3600),
            refreshTokenExpiresAt: anchor.addingTimeInterval(172_800),
            scopes: ["user:inference", "user:profile"]
        )
        let merged = stored.applying(tokens)
        #expect(merged.scopes == ["user:inference", "user:profile"])
        #expect(merged.refreshTokenExpiresAt == anchor.addingTimeInterval(172_800))
    }

    @Test("A merged credential is immediately usable and no longer near expiry")
    func mergedCredentialIsFresh() {
        let tokens = RefreshedTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: anchor.addingTimeInterval(28_800)
        )
        let merged = stored.applying(tokens)
        #expect(merged.isExpired(asOf: anchor) == false)
        #expect(merged.expiresSoon(asOf: anchor, lead: 300) == false)
        #expect(merged.usableRefreshToken(asOf: anchor) == "new-refresh")
    }
}
