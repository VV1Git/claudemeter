import Foundation
import Testing

import UsageCore

// Nothing here reaches the network or the Keychain. Every case exercises the pure half of
// the sign-in flow: the PKCE pair, the URL the browser is sent to, and the two shapes the
// authorization code comes back in.

// MARK: - PKCE

@Test func verifierAndChallengeMatchTheRFCVector() {
    // RFC 7636 appendix B, so the digest and both base64url encodings are checked against a
    // value neither this code nor its test chose.
    let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func generatedVerifiersAreURLSafeAndUnpadded() {
    let pair = PKCEPair()
    #expect(!pair.verifier.contains("+"))
    #expect(!pair.verifier.contains("/"))
    #expect(!pair.verifier.contains("="))
    #expect(!pair.challenge.contains("+"))
    #expect(!pair.challenge.contains("/"))
    #expect(!pair.challenge.contains("="))
    // RFC 7636 puts the verifier between 43 and 128 characters.
    #expect(pair.verifier.count >= 43)
    #expect(pair.verifier.count <= 128)
}

@Test func generatedVerifiersDiffer() {
    #expect(PKCEPair().verifier != PKCEPair().verifier)
}

// MARK: - The authorization URL

private func queryItems(of url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary(
        uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Test func authorizationURLCarriesEveryParameterTheEndpointNeeds() {
    let url = OAuthSignIn.authorizationURL(
        challenge: "the-challenge", state: "the-state", redirectURI: "http://localhost:7717/callback")
    let items = queryItems(of: url)

    // The subscription authorize endpoint, not the Console one. Pinned because using Console
    // here mints a token that exchanges cleanly and is then refused by the usage endpoint,
    // which reports subscription limits and has no subscription to report for such a token.
    #expect(url.host == "claude.com")
    #expect(url.path == "/cai/oauth/authorize")
    #expect(items["client_id"] == TokenRefresher.defaultClientID)
    #expect(items["response_type"] == "code")
    #expect(items["code"] == "true")
    #expect(items["redirect_uri"] == "http://localhost:7717/callback")
    #expect(items["code_challenge"] == "the-challenge")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == "the-state")
    #expect(items["scope"] == OAuthSignIn.scopes.joined(separator: " "))
}

@Test func theScopeSetMatchesTheOneTheUsageEndpointAccepts() {
    // These five are what Claude Code's own working credential carries. Pinned so the set stays
    // matched to one known to be accepted, rather than narrowed on reasoning about what a
    // read-only meter "should" need.
    #expect(
        OAuthSignIn.scopes == [
            "user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers",
            "user:file_upload",
        ])
    // The sixth the CLI asks for, deliberately not requested: the working credential does not
    // carry it, so it is not needed, and it is the one scope that could mint API keys.
    #expect(!OAuthSignIn.scopes.contains("org:create_api_key"))
}

@Test func loopbackRedirectNamesThePortItListensOn() {
    #expect(OAuthSignIn.loopbackRedirectURI(port: 7717) == "http://localhost:7717/callback")
}

// MARK: - The pasted code

@Test func aPastedCodeCarriesTheStateAfterAHash() throws {
    // What the callback page shows is `code#state`, so the halves are separated here rather
    // than sent to the token endpoint as one string.
    let parsed = try OAuthSignIn.parsePastedCode("the-code#the-state")
    #expect(parsed.code == "the-code")
    #expect(parsed.state == "the-state")
}

@Test func aPastedCodeWithoutAStateIsAccepted() throws {
    let parsed = try OAuthSignIn.parsePastedCode("the-code")
    #expect(parsed.code == "the-code")
    #expect(parsed.state == nil)
}

@Test func aPastedCodeIsTrimmed() throws {
    // Copied out of a browser, so leading and trailing whitespace is the common case, not
    // the odd one — the same lesson `CredentialStore.normalisedToken` already carries.
    let parsed = try OAuthSignIn.parsePastedCode("  the-code#the-state\n")
    #expect(parsed.code == "the-code")
    #expect(parsed.state == "the-state")
}

@Test func anEmptyPastedCodeIsRejected() {
    #expect(throws: OAuthSignInError.self) { try OAuthSignIn.parsePastedCode("   \n") }
}

@Test func aPastedCodeThatIsOnlyAStateIsRejected() {
    #expect(throws: OAuthSignInError.self) { try OAuthSignIn.parsePastedCode("#the-state") }
}

// MARK: - The loopback callback

@Test func aLoopbackCallbackYieldsItsCodeAndState() throws {
    let parsed = try OAuthSignIn.parseCallback(
        requestTarget: "/callback?code=the-code&state=the-state")
    #expect(parsed.code == "the-code")
    #expect(parsed.state == "the-state")
}

@Test func aLoopbackCallbackPercentDecodesItsCode() throws {
    let parsed = try OAuthSignIn.parseCallback(
        requestTarget: "/callback?code=a%2Bb%2Fc&state=s")
    #expect(parsed.code == "a+b/c")
}

@Test func aLoopbackCallbackCarryingAnErrorReportsIt() {
    #expect(throws: OAuthSignInError.denied("access_denied")) {
        try OAuthSignIn.parseCallback(
            requestTarget: "/callback?error=access_denied&error_description=nope")
    }
}

@Test func aLoopbackRequestForAnotherPathIsNotTheCallback() {
    // Browsers ask for `/favicon.ico` on the way past, and answering one as though it were
    // the callback would fail the sign-in for a request the user never made.
    #expect(throws: OAuthSignInError.self) {
        try OAuthSignIn.parseCallback(requestTarget: "/favicon.ico")
    }
}

@Test func aLoopbackCallbackWithoutACodeIsRejected() {
    #expect(throws: OAuthSignInError.self) {
        try OAuthSignIn.parseCallback(requestTarget: "/callback?state=the-state")
    }
}

// MARK: - The request line

private func target(_ request: String) -> String? {
    OAuthSignIn.requestTarget(inRequest: Data(request.utf8))
}

@Test func theRequestTargetIsTheMiddleFieldOfTheRequestLine() {
    #expect(
        target("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
            == "/callback?code=abc&state=xyz")
}

@Test func aRequestThatIsNotAGETIsIgnored() {
    // Nothing legitimate POSTs to this port, so answering one would only ever be answering
    // something that was not the browser coming back.
    #expect(target("POST /callback HTTP/1.1\r\n\r\n") == nil)
}

@Test func aTruncatedRequestLineIsIgnored() {
    #expect(target("GET\r\n\r\n") == nil)
    #expect(target("") == nil)
}

@Test func aRequestLineThatIsNotTextIsIgnored() {
    // A TLS ClientHello arriving on a plaintext port is the realistic case: someone typed
    // `https://localhost:PORT`. It decodes to nothing readable and must not be answered.
    #expect(OAuthSignIn.requestTarget(inRequest: Data([0x16, 0x03, 0x01, 0xFF, 0xFE])) == nil)
}

// MARK: - State

@Test func aMismatchedStateIsRefused() {
    // The state is the only thing tying the code in hand to the request this app started.
    #expect(throws: OAuthSignInError.stateMismatch) {
        try OAuthSignIn.validate(
            AuthorizationCode(code: "the-code", state: "somebody-elses"), expecting: "ours")
    }
}

@Test func aMatchingStateIsAccepted() throws {
    try OAuthSignIn.validate(
        AuthorizationCode(code: "the-code", state: "ours"), expecting: "ours")
}

@Test func anAbsentStateIsAccepted() throws {
    // The manual page does not always echo one back, and refusing the code on that basis
    // would fail a sign-in that is otherwise perfectly good.
    try OAuthSignIn.validate(AuthorizationCode(code: "the-code", state: nil), expecting: "ours")
}

// MARK: - The exchange request

@Test func theExchangeBodyMatchesWhatTheCLISends() throws {
    let body = try OAuthSignIn.exchangeBody(
        AuthorizationCode(code: "the-code", state: "the-state"),
        verifier: "the-verifier",
        redirectURI: "http://localhost:7717/callback",
        clientID: "the-client")
    let decoded = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: String])

    #expect(decoded["grant_type"] == "authorization_code")
    #expect(decoded["code"] == "the-code")
    #expect(decoded["redirect_uri"] == "http://localhost:7717/callback")
    #expect(decoded["client_id"] == "the-client")
    #expect(decoded["code_verifier"] == "the-verifier")
    #expect(decoded["state"] == "the-state")
}

@Test func theExchangeBodyOmitsAnAbsentState() throws {
    let body = try OAuthSignIn.exchangeBody(
        AuthorizationCode(code: "the-code", state: nil),
        verifier: "the-verifier",
        redirectURI: OAuthSignIn.manualRedirectURI,
        clientID: "the-client")
    let decoded = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: String])

    #expect(decoded["state"] == nil)
    #expect(decoded["redirect_uri"] == OAuthSignIn.manualRedirectURI)
}

// MARK: - What the exchange produces

@Test func anExchangedTokenBecomesARenewableCredential() throws {
    let json = """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,
         "scope":"user:inference user:profile"}
        """
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let tokens = try TokenRefresher.decodeTokens(
        from: Data(json.utf8), refreshedWith: "", now: anchor)
    let credentials = OAuthSignIn.credentials(from: tokens, clientID: "the-client")

    #expect(credentials.accessToken == "new-access")
    #expect(credentials.clientID == "the-client")
    #expect(credentials.expiresAt == anchor.addingTimeInterval(28_800))
    // The whole point of the flow over a pasted token: something to renew with, so this
    // never has to be done twice.
    #expect(credentials.usableRefreshToken(asOf: anchor) == "new-refresh")
    #expect(credentials.scopes == ["user:inference", "user:profile"])
}

@Test func anExchangeThatReturnedNoRefreshTokenStillYieldsAUsableCredential() throws {
    // Degrades to exactly what a pasted `claude setup-token` token is: good until it is
    // refused, with nothing to renew it. Worth having rather than failing the sign-in.
    let json = #"{"access_token":"new-access","expires_in":3600}"#
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let tokens = try TokenRefresher.decodeTokens(
        from: Data(json.utf8), refreshedWith: "", now: anchor)
    let credentials = OAuthSignIn.credentials(from: tokens, clientID: nil)

    #expect(credentials.accessToken == "new-access")
    #expect(credentials.usableRefreshToken(asOf: anchor) == nil)
}
