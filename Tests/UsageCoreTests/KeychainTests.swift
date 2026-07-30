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
}
