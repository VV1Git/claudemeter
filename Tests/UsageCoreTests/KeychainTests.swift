import Foundation
import Testing

import UsageCore

// These tests never call `Keychain.readCredentials()` or `Keychain.partitionIdentities()` —
// that would touch the real login keychain. Everything goes through the pure
// `parseCredentials` and `partitionIdentities(fromACLDescription:)` entry points, so no
// filesystem, network, or Keychain access is involved.

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

// MARK: - Partition list

/// The ACL description as securityd stores it: a plist, hex-encoded, because the field is
/// nominally display text. `hexPlist` reproduces that encoding rather than pasting a captured
/// 600-character literal; `beginsWithXMLSignature` is what ties it back to the real bytes, which
/// start `3c3f786d6c` — `<?xml`.
private func hexPlist(partitions: [String]) -> String {
    hex(plist(partitions: partitions))
}

private func plist(partitions: [String]) -> String {
    let entries = partitions.map { "<string>\($0)</string>" }.joined()
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<plist version=\"1.0\"><dict><key>Partitions</key><array>\(entries)</array>"
        + "<key>Version</key><integer>1</integer></dict></plist>"
}

private func hex(_ text: String) -> String {
    text.utf8.map { String(format: "%02x", $0) }.joined()
}

@Suite("Keychain partition list")
struct KeychainPartitionTests {
    @Test("The encoded description is what securityd actually stores")
    func fixtureMatchesObservedBytes() {
        #expect(hexPlist(partitions: ["apple-tool:"]).hasPrefix("3c3f786d6c"))
    }

    @Test("A single identity is read out of the encoded description")
    func singleIdentity() {
        #expect(
            Keychain.partitionIdentities(fromACLDescription: hexPlist(partitions: ["apple-tool:"]))
                == ["apple-tool:"])
    }

    @Test("Both identities are read, in the order stored")
    func twoIdentities() {
        let description = hexPlist(partitions: ["apple-tool:", "teamid:7DJSY2AKJK"])
        #expect(
            Keychain.partitionIdentities(fromACLDescription: description)
                == ["apple-tool:", "teamid:7DJSY2AKJK"])
    }

    @Test("A description that is already plist bytes is read as it stands")
    func undecoratedPlist() {
        #expect(
            Keychain.partitionIdentities(fromACLDescription: plist(partitions: ["apple-tool:"]))
                == ["apple-tool:"])
    }

    @Test("Surrounding whitespace does not defeat the decode")
    func trimsWhitespace() {
        let description = "  \n\(hexPlist(partitions: ["apple-tool:"]))\n"
        #expect(Keychain.partitionIdentities(fromACLDescription: description) == ["apple-tool:"])
    }

    @Test("An item admitting nobody reads as empty, which is an answer")
    func emptyPartitionList() {
        #expect(Keychain.partitionIdentities(fromACLDescription: hexPlist(partitions: [])) == [])
    }

    // Every case below must be nil rather than `[]`: "could not tell" and "admits nobody" drive
    // opposite decisions, and a parse failure rendering as a lockout would tell users to repair
    // an item that is fine.
    @Test("An unreadable description is nil, never an empty list")
    func unreadableDescriptions() {
        #expect(Keychain.partitionIdentities(fromACLDescription: "") == nil)
        #expect(Keychain.partitionIdentities(fromACLDescription: "   \n ") == nil)
        // Odd-length hex, so the hex decode declines and the raw text is not a plist either.
        #expect(Keychain.partitionIdentities(fromACLDescription: "3c3f786d6") == nil)
        #expect(Keychain.partitionIdentities(fromACLDescription: "not hex at all") == nil)
        // Even-length, decodes cleanly, and decodes to something that is not a plist.
        #expect(Keychain.partitionIdentities(fromACLDescription: hex("hello!")) == nil)
    }

    @Test("A plist with no Partitions key is nil")
    func plistWithoutPartitions() {
        let other = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<plist version=\"1.0\"><dict><key>Version</key><integer>1</integer></dict></plist>"
        #expect(Keychain.partitionIdentities(fromACLDescription: hex(other)) == nil)
    }

    @Test("Partitions holding something other than an array of strings is nil")
    func partitionsWrongShape() {
        let scalar = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<plist version=\"1.0\"><dict><key>Partitions</key>"
            + "<string>apple-tool:</string></dict></plist>"
        #expect(Keychain.partitionIdentities(fromACLDescription: hex(scalar)) == nil)
    }

    @Test("A lockout is the CLI's identity missing, and nothing else")
    func lockoutVerdict() {
        #expect(Keychain.isCLILockedOut(partitions: nil) == false)
        #expect(Keychain.isCLILockedOut(partitions: ["apple-tool:"]) == false)
        #expect(Keychain.isCLILockedOut(partitions: ["teamid:7DJSY2AKJK", "apple-tool:"]) == false)
        #expect(Keychain.isCLILockedOut(partitions: ["teamid:7DJSY2AKJK"]) == true)
        #expect(Keychain.isCLILockedOut(partitions: []) == true)
    }

    @Test("The repair command names every identity it is given, and takes no password")
    func repairCommand() {
        let command = Keychain.partitionRepairCommand(
            admitting: [Keychain.cliPartitionIdentity, "teamid:ABCDE12345"], account: "someone")
        // `-S` replaces the list, so dropping either identity would move the lockout rather than
        // clear it.
        #expect(command.contains("-S 'apple-tool:,teamid:ABCDE12345'"))
        // Exact service match, so it cannot reach one of the item's suffixed siblings.
        #expect(command.contains("-s '\(Keychain.service)'"))
        #expect(command.contains("-a 'someone'"))
        #expect(command.contains("set-generic-password-partition-list"))
        // `-k` would put the login password in shell history, and `security` says so itself.
        #expect(command.contains(" -k ") == false)
        // Nothing here may decrypt an item.
        #expect(command.contains(" -w") == false)
        #expect(command.contains(" -g") == false)
    }

    /// The identity is read from the running code rather than hard-coded, because a command built
    /// around the wrong one would evict the copy of ClaudeMeter the user is looking at. Reading a
    /// process's own signature touches no Keychain, so it is in scope for this file. What the test
    /// binary is signed with varies by machine, so what is asserted is the shape: one of the three
    /// forms securityd files code under, or an honest `nil`.
    @Test("This build's own partition identity is derived, not assumed")
    func ownIdentity() {
        guard let identity = Keychain.appPartitionIdentity else { return }
        #expect(
            identity.hasPrefix("teamid:") || identity.hasPrefix("cdhash:")
                || identity == "unsigned:")
        // A prefix with nothing after it would name no identity at all, and `-S` would take it
        // as a request to admit something that does not exist.
        #expect(identity.count > "unsigned:".count || identity == "unsigned:")
    }

    // MARK: - Round trip

    /// The dedicated credential is stored in Claude Code's own JSON shape rather than a private
    /// one, so a single parser reads both. That only holds if the encoder and the parser agree,
    /// and they are written far apart — hence a round trip rather than two sets of assertions.
    @Test("Encoding and parsing a credential is lossless for every field carried")
    func encodeParseRoundTrip() throws {
        let original = try parse(credentialShapeJSON)
        let encoded = try Keychain.encode(original)
        let recovered = try Keychain.parseCredentials(from: encoded)
        #expect(recovered == original)
    }

    /// Epoch milliseconds are stored as whole numbers, so a deadline carrying sub-millisecond
    /// precision must not come back a hair early — the whole point of a lead time is that the
    /// token outlives the request, and a re-read landing before the stored instant erodes it.
    @Test("A round-tripped deadline never moves backwards")
    func roundTripDeadlineDoesNotRegress() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000.9994)
        let original = ClaudeCredentials(
            accessToken: "t", expiresAt: expiry, subscriptionType: nil, rateLimitTier: nil)
        let recovered = try Keychain.parseCredentials(from: Keychain.encode(original))
        #expect(recovered.expiresAt >= expiry)
        #expect(recovered.expiresAt.timeIntervalSince(expiry) < 0.001)
    }

    /// A credential with nothing optional set must still encode to something the parser accepts.
    /// The encoder omits absent fields rather than writing nulls, and a null `accessToken` would
    /// fail the parse outright.
    @Test("A minimal credential survives the round trip")
    func minimalRoundTrip() throws {
        let minimal = ClaudeCredentials(
            accessToken: "only-a-token",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            subscriptionType: nil,
            rateLimitTier: nil)
        let recovered = try Keychain.parseCredentials(from: Keychain.encode(minimal))
        #expect(recovered == minimal)
        #expect(recovered.refreshToken == nil)
        #expect(recovered.scopes.isEmpty)
    }

    /// The two items must never be confused for one another: one is read-only and shared with the
    /// CLI, the other is this app's to write. A collision would put a dedicated token into Claude
    /// Code's item, which is the exact write the redesign exists to prevent.
    @Test("This app's own item is a different service from Claude Code's")
    func ownServiceIsDistinct() {
        #expect(Keychain.ownService != Keychain.service)
        #expect(Keychain.ownService.contains("ClaudeMeter"))
    }

    // MARK: - Errors

    /// `AppModel` routes on this: an authorization problem becomes a button, anything else
    /// becomes a fault. Misclassifying `.notFound` as recoverable would offer the user an
    /// Authorize button for a machine that has never signed in.
    @Test("Only the two authorization failures are offered as recoverable")
    func authorizationProblemClassification() {
        #expect(KeychainError.accessDenied.isAuthorizationProblem)
        #expect(KeychainError.authorizationCancelled.isAuthorizationProblem)
        #expect(KeychainError.notFound.isAuthorizationProblem == false)
        #expect(KeychainError.malformed("x").isAuthorizationProblem == false)
        #expect(KeychainError.unhandled(-1).isAuthorizationProblem == false)
    }

    /// Every case is shown to the user verbatim, so an empty description would render a blank
    /// notice row with no explanation of why the meter stopped.
    @Test("Every error states itself")
    func everyErrorDescribes() {
        let errors: [KeychainError] = [
            .notFound, .malformed("detail"), .accessDenied, .authorizationCancelled,
            .unhandled(-25300),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - The dedicated token

    /// The bug this covers: the value stored was trimmed and the value validated was not, so a
    /// token copied out of a terminal was saved, then spent as a different string, refused, and
    /// deleted — with the user told they had pasted it wrong.
    @Test("A pasted token is normalised the same way wherever it is asked for")
    func pastedTokenIsTrimmed() throws {
        let bare = "sk-ant-oat01-EXAMPLE"
        for pasted in ["\(bare)\n", "  \(bare)  ", "\t\(bare)\r\n", bare] {
            #expect(try CredentialStore.normalisedToken(pasted) == bare)
        }
    }

    /// Whitespace-only input is not a token with an empty name; it is a user who pressed Use on an
    /// empty field, and storing it would leave the app polling with an empty bearer header.
    @Test("A blank token is refused rather than stored")
    func blankTokenRefused() {
        for blank in ["", "   ", "\n", "\t \n"] {
            #expect(throws: KeychainError.self) { try CredentialStore.normalisedToken(blank) }
        }
    }

    /// `-S` replaces a partition list rather than adding to it, so an argument that splits does
    /// not fail harmlessly — it revokes access on whatever item it lands on instead. The account
    /// is read from the item's stored attribute, so it is not this app's to assume well-formed.
    @Test("Every field of the repair command is quoted, including the account")
    func repairCommandQuotesTheAccount() {
        let command = Keychain.partitionRepairCommand(
            admitting: ["apple-tool:"], account: "first last")
        #expect(command.contains("-a 'first last'"))
        // The whole point: no bare occurrence that the shell would split into two words.
        #expect(command.contains("-a first last") == false)
    }
}
