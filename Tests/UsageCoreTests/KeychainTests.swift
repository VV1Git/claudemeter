import Foundation
import Testing

import UsageCore

// These tests never call `Keychain.readCredentials()` — that would touch the real
// login keychain and prompt. Everything goes through the pure `parseCredentials`
// entry point, so no filesystem, network, or Keychain access is involved.

private let credentialShapeJSON = """
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-EXAMPLE",
    "refreshToken": "sk-ant-ort01-EXAMPLE",
    "expiresAt": 1700000000000,
    "refreshTokenExpiresAt": 1701728000000,
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "example_plan",
    "rateLimitTier": "example_tier"
  }
}
"""

private func parse(_ json: String) throws -> ClaudeCredentials {
    try Keychain.parseCredentials(from: Data(json.utf8))
}

/// The thrown `KeychainError`, or `nil` when the parse succeeded or threw something else.
private func failure(parsing json: String) -> KeychainError? {
    do {
        _ = try Keychain.parseCredentials(from: Data(json.utf8))
        return nil
    } catch let error as KeychainError {
        return error
    } catch {
        return nil
    }
}

private func isMalformed(_ error: KeychainError?) -> Bool {
    guard let error else { return false }
    if case .malformed = error { return true }
    return false
}

@Suite("Keychain credential parsing")
struct KeychainTests {
    @Test("Service name matches what Claude Code writes")
    func serviceName() {
        #expect(Keychain.service == "Claude Code-credentials")
    }

    @Test("Parses the full credential shape")
    func parsesFullShape() throws {
        let credentials = try parse(credentialShapeJSON)
        #expect(credentials.accessToken == "sk-ant-oat01-EXAMPLE")
        #expect(credentials.subscriptionType == "example_plan")
        #expect(credentials.rateLimitTier == "example_tier")
    }

    @Test("expiresAt is epoch milliseconds, not seconds")
    func millisecondsBecomeSeconds() throws {
        let credentials = try parse(credentialShapeJSON)
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        // Guard against the seconds/milliseconds mix-up specifically: the wrong
        // reading lands ~54,000 years in the future.
        #expect(credentials.expiresAt.timeIntervalSince1970 < 2_000_000_000)
    }

    @Test("expiresAt is tolerated as a numeric string")
    func millisecondsAsString() throws {
        let json = """
        {"claudeAiOauth": {"accessToken": "t", "expiresAt": "1700000000000"}}
        """
        let credentials = try parse(json)
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Optional metadata may be absent")
    func optionalMetadataAbsent() throws {
        let json = """
        {"claudeAiOauth": {"accessToken": "t", "expiresAt": 1700000000000}}
        """
        let credentials = try parse(json)
        #expect(credentials.subscriptionType == nil)
        #expect(credentials.rateLimitTier == nil)
    }

    @Test("Unknown fields do not break the parse")
    func unknownFieldsIgnored() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "t", "expiresAt": 1700000000000,
            "somethingNewAnthropicAdded": {"nested": [1, 2, 3]}
          },
          "otherTopLevelKey": 7
        }
        """
        let credentials = try parse(json)
        #expect(credentials.accessToken == "t")
    }

    @Test("Missing claudeAiOauth throws .malformed")
    func missingOAuthObject() {
        #expect(isMalformed(failure(parsing: #"{"someOtherProvider": {"accessToken": "t"}}"#)))
    }

    @Test("Missing accessToken throws .malformed")
    func missingAccessToken() {
        #expect(isMalformed(failure(parsing: #"{"claudeAiOauth": {"expiresAt": 1700000000000}}"#)))
    }

    @Test("Empty accessToken throws .malformed")
    func emptyAccessToken() {
        let json = #"{"claudeAiOauth": {"accessToken": "", "expiresAt": 1700000000000}}"#
        #expect(isMalformed(failure(parsing: json)))
    }

    @Test("Missing expiresAt throws .malformed")
    func missingExpiresAt() {
        #expect(isMalformed(failure(parsing: #"{"claudeAiOauth": {"accessToken": "t"}}"#)))
    }

    @Test("Non-numeric expiresAt throws .malformed")
    func nonNumericExpiresAt() {
        let json = #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": "never"}}"#
        #expect(isMalformed(failure(parsing: json)))
    }

    @Test("Garbage and empty payloads throw .malformed, never crash")
    func garbagePayloads() {
        #expect(isMalformed(failure(parsing: "not json at all {{{")))
        #expect(isMalformed(failure(parsing: "")))
        #expect(isMalformed(failure(parsing: "[]")))
    }

    @Test("Expiry compares in both directions, inclusive at the deadline")
    func expiryComparison() throws {
        let credentials = try parse(credentialShapeJSON)
        let expiry = credentials.expiresAt
        #expect(credentials.isExpired(asOf: expiry.addingTimeInterval(1)))
        #expect(credentials.isExpired(asOf: expiry) == true)
        #expect(credentials.isExpired(asOf: expiry.addingTimeInterval(-1)) == false)
        #expect(credentials.isExpired(asOf: expiry.addingTimeInterval(-86_400)) == false)
    }

    @Test("Identical JSON parses to equal values")
    func equalForIdenticalInput() throws {
        let first = try parse(credentialShapeJSON)
        let second = try parse(credentialShapeJSON)
        #expect(first == second)
    }

    // MARK: Renewal fields

    @Test("The refresh token and its own deadline are read")
    func parsesRenewalFields() throws {
        let credentials = try parse(credentialShapeJSON)
        #expect(credentials.refreshToken == "sk-ant-ort01-EXAMPLE")
        #expect(
            credentials.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_701_728_000))
        #expect(credentials.scopes == ["user:inference", "user:profile"])
    }

    @Test("A credential with no refresh token cannot be renewed")
    func absentRefreshToken() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1700000000000}}"#
        let credentials = try parse(json)
        #expect(credentials.refreshToken == nil)
        #expect(credentials.usableRefreshToken(asOf: Date()) == nil)
        #expect(credentials.scopes.isEmpty)
    }

    @Test("An empty refresh token counts as none, not as a token worth spending")
    func emptyRefreshToken() throws {
        let json = """
        {"claudeAiOauth": {"accessToken": "t", "refreshToken": "", "expiresAt": 1700000000000}}
        """
        let credentials = try parse(json)
        #expect(credentials.refreshToken == nil)
        #expect(credentials.usableRefreshToken(asOf: Date()) == nil)
    }

    @Test("A refresh token past its own deadline is not usable")
    func expiredRefreshToken() throws {
        let credentials = try parse(credentialShapeJSON)
        let deadline = try #require(credentials.refreshTokenExpiresAt)
        #expect(credentials.usableRefreshToken(asOf: deadline.addingTimeInterval(-1)) != nil)
        #expect(credentials.usableRefreshToken(asOf: deadline) == nil)
        #expect(credentials.usableRefreshToken(asOf: deadline.addingTimeInterval(1)) == nil)
    }

    @Test("A refresh token with no stated deadline is usable")
    func refreshTokenWithoutDeadline() throws {
        let json = """
        {"claudeAiOauth": {"accessToken": "t", "refreshToken": "r", "expiresAt": 1700000000000}}
        """
        let credentials = try parse(json)
        #expect(credentials.usableRefreshToken(asOf: Date.distantFuture) == "r")
    }

    @Test("The renewal window opens before expiry, not at it")
    func expiresSoonLeadsExpiry() throws {
        let credentials = try parse(credentialShapeJSON)
        let expiry = credentials.expiresAt
        #expect(credentials.expiresSoon(asOf: expiry.addingTimeInterval(-60), lead: 300))
        #expect(credentials.expiresSoon(asOf: expiry.addingTimeInterval(-300), lead: 300))
        #expect(credentials.expiresSoon(asOf: expiry.addingTimeInterval(-301), lead: 300) == false)
        // Already past its deadline is still "soon" — there is nothing later than expired.
        #expect(credentials.expiresSoon(asOf: expiry.addingTimeInterval(3600), lead: 300))
    }

    @Test("The client identifier is read when present, and absent otherwise")
    func clientIdentifier() throws {
        #expect(try parse(credentialShapeJSON).clientID == nil)
        let json = """
        {"claudeAiOauth": {"accessToken": "t", "expiresAt": 1700000000000, "clientId": "abc"}}
        """
        #expect(try parse(json).clientID == "abc")
    }

    @Test("A renewal field that changes type costs only that field")
    func renewalFieldTypeChange() throws {
        // The access token is what the app needs; `scopes` arriving as a string, or a
        // numeric `subscriptionType`, must not take the whole item down with it.
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "t", "expiresAt": 1700000000000,
            "scopes": "user:inference", "subscriptionType": 7, "refreshToken": 42
          }
        }
        """
        let credentials = try parse(json)
        #expect(credentials.accessToken == "t")
        #expect(credentials.scopes.isEmpty)
        #expect(credentials.subscriptionType == nil)
        #expect(credentials.refreshToken == nil)
    }
}
