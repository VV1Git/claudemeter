import Foundation
import Security

// MARK: - Credentials

/// The subset of the Claude Code credential item this app needs.
///
/// The refresh token is carried as well as the access token: an access token lasts
/// hours, and an app that only ever reads one spends much of its life staring at an
/// expired credential. `TokenRefresher` trades the refresh token for a new pair on
/// the same endpoint and with the same client identifier the CLI uses, so the two
/// stay interchangeable.
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date
    /// Absent on credential shapes that predate the field, and on tokens minted by
    /// `claude setup-token`, which have nothing to refresh with.
    public let refreshToken: String?
    /// When the refresh token itself stops working. Past this, no amount of refreshing
    /// helps and the only fix is signing in again.
    public let refreshTokenExpiresAt: Date?
    /// Sent back on refresh so the renewed token keeps the grants the old one had.
    public let scopes: [String]
    /// The OAuth client the tokens were issued to. Written by newer CLI versions; when
    /// absent, `TokenRefresher` falls back to Claude Code's published client identifier.
    public let clientID: String?
    /// The plan identifier the CLI writes, when it writes one. Absent on credential shapes
    /// that predate the field.
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        expiresAt: Date,
        refreshToken: String? = nil,
        refreshTokenExpiresAt: Date? = nil,
        scopes: [String] = [],
        clientID: String? = nil,
        subscriptionType: String?,
        rateLimitTier: String?
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.clientID = clientID
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// Expiry is treated as inclusive: a token whose deadline is exactly `now` is
    /// already unusable, since the request would land after it.
    public func isExpired(asOf now: Date) -> Bool {
        expiresAt <= now
    }

    /// True when the token is expired, or close enough that a request started now could
    /// land after it. The lead time is what keeps a poll from riding a token that dies
    /// mid-flight — the one case a plain `isExpired` check cannot catch.
    public func expiresSoon(asOf now: Date, lead: TimeInterval) -> Bool {
        expiresAt <= now.addingTimeInterval(lead)
    }

    /// A refresh token that is present, non-empty, and not itself past its deadline.
    /// Nil means the credentials cannot be renewed and the user has to sign in again.
    public func usableRefreshToken(asOf now: Date) -> String? {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        if let refreshTokenExpiresAt, refreshTokenExpiresAt <= now { return nil }
        return refreshToken
    }
}

// MARK: - Errors

public enum KeychainError: Error, Sendable, Equatable {
    /// No generic-password item for `Keychain.service` — Claude Code has never signed in here.
    case notFound
    /// The item exists but its payload isn't the credential JSON this app understands.
    case malformed(String)
    /// Any other `SecItemCopyMatching` result, including the user denying access.
    case unhandled(OSStatus)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials found in the Keychain."
        case .malformed(let detail):
            return "Claude Code credentials could not be read: \(detail)"
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain access failed: \(message)"
        }
    }
}

// MARK: - Keychain access

/// Access to the credential item Claude Code stores.
///
/// The item is shared with the CLI, so the only write this app makes is the narrow one
/// in `storeRefreshedTokens`: a compare-and-swap that replaces the rotated OAuth fields
/// and nothing else, and refuses the write outright if the CLI rotated the token first.
/// That is the same discipline Claude Code applies to its own writes, which is what lets
/// the two processes refresh without either clobbering the other.
public enum Keychain {
    public static let service = "Claude Code-credentials"

    /// Reads and parses the credential item.
    public static func readCredentials() throws -> ClaudeCredentials {
        try parseCredentials(from: readPayload())
    }

    /// The raw item data, before any interpretation. Kept separate from the parse so a
    /// write can merge into the exact JSON that is there rather than a re-encoding of the
    /// fields this app happens to understand.
    private static func readPayload() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.malformed("Keychain item carried no data")
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Writes a refreshed token pair back into the shared item.
    ///
    /// Two things make this safe to do to an item another process owns. The write is a
    /// merge, not a replacement: the payload is re-read, the four rotated fields are
    /// overwritten in place, and every other key — at the top level and inside
    /// `claudeAiOauth` — survives untouched, including ones this app has never heard of.
    /// And it is conditional: if the stored refresh token is no longer the one this
    /// refresh was made with, Claude Code rotated it in the meantime, its tokens are the
    /// newer pair, and ours are discarded rather than written over them.
    ///
    /// Returns false for that lost race, which is not an error — the caller re-reads and
    /// uses what the CLI wrote.
    @discardableResult
    public static func storeRefreshedTokens(
        _ tokens: RefreshedTokens, replacing expectedRefreshToken: String
    ) throws -> Bool {
        let payload = try readPayload()
        guard var root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw KeychainError.malformed("Credential payload is not readable credential JSON")
        }
        guard var oauth = root[Self.oauthKey] as? [String: Any] else {
            throw KeychainError.malformed("Credential JSON has no `claudeAiOauth` object")
        }
        guard oauth["refreshToken"] as? String == expectedRefreshToken else { return false }

        oauth["accessToken"] = tokens.accessToken
        oauth["refreshToken"] = tokens.refreshToken
        oauth["expiresAt"] = Self.epochMilliseconds(tokens.expiresAt)
        // Only written when the server sent one: a refresh that omits the field is saying
        // the refresh token's own deadline has not moved, and inventing one from `nil`
        // would erase the deadline already stored.
        if let refreshExpiry = tokens.refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = Self.epochMilliseconds(refreshExpiry)
        }
        if !tokens.scopes.isEmpty {
            oauth["scopes"] = tokens.scopes
        }
        root[Self.oauthKey] = oauth

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: root)
        } catch {
            throw KeychainError.malformed("Refreshed credentials could not be encoded")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: encoded] as CFDictionary)

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private static let oauthKey = "claudeAiOauth"

    /// The CLI stores deadlines as epoch milliseconds, and as whole numbers. Rounding here
    /// rather than truncating a `Double` keeps a re-read from landing a millisecond early.
    private static func epochMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Pure parse, exposed so tests run with no Keychain access.
    public static func parseCredentials(from data: Data) throws -> ClaudeCredentials {
        guard !data.isEmpty else {
            throw KeychainError.malformed("Credential payload was empty")
        }

        let file: CredentialFile
        do {
            file = try JSONDecoder().decode(CredentialFile.self, from: data)
        } catch {
            throw KeychainError.malformed("Credential payload is not readable credential JSON")
        }

        guard let oauth = file.claudeAiOauth else {
            throw KeychainError.malformed("Credential JSON has no `claudeAiOauth` object")
        }
        guard let token = oauth.accessToken, !token.isEmpty else {
            throw KeychainError.malformed("Credential JSON has no `accessToken`")
        }
        guard let expiry = oauth.expiresAt else {
            throw KeychainError.malformed("Credential JSON has no `expiresAt`")
        }

        return ClaudeCredentials(
            accessToken: token,
            // `expiresAt` is epoch milliseconds (13 digits, e.g. 1700000000000), not seconds.
            expiresAt: Date(timeIntervalSince1970: expiry.milliseconds / 1000),
            // An empty refresh token is the same as none: `setup-token` credentials carry
            // one, and treating it as usable would spend a request to be told so.
            refreshToken: oauth.refreshToken.flatMap { $0.isEmpty ? nil : $0 },
            refreshTokenExpiresAt: oauth.refreshTokenExpiresAt.map {
                Date(timeIntervalSince1970: $0.milliseconds / 1000)
            },
            scopes: oauth.scopes ?? [],
            clientID: oauth.clientId,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }
}

// MARK: - Wire shape

/// The on-disk credential JSON. Kept separate from `ClaudeCredentials` so the
/// domain type isn't hostage to the CLI's storage format, and every field is
/// optional so an added or dropped key can't make the whole item unreadable.
private struct CredentialFile: Decodable {
    let claudeAiOauth: OAuth?

    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: EpochMilliseconds?
        let refreshToken: String?
        let refreshTokenExpiresAt: EpochMilliseconds?
        let scopes: [String]?
        let clientId: String?
        let subscriptionType: String?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case accessToken, expiresAt, refreshToken, refreshTokenExpiresAt
            case scopes, clientId, subscriptionType, rateLimitTier
        }

        /// Every field is read independently. Optionality alone is not enough: a key that
        /// changes *type* — `scopes` arriving as a string, a numeric `subscriptionType` —
        /// would otherwise fail the whole decode and take the access token with it, and the
        /// two fields worth failing over are checked by the caller instead.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
            expiresAt = try? container.decodeIfPresent(EpochMilliseconds.self, forKey: .expiresAt)
            refreshToken = try? container.decodeIfPresent(String.self, forKey: .refreshToken)
            refreshTokenExpiresAt = try? container.decodeIfPresent(
                EpochMilliseconds.self, forKey: .refreshTokenExpiresAt)
            scopes = try? container.decodeIfPresent([String].self, forKey: .scopes)
            clientId = try? container.decodeIfPresent(String.self, forKey: .clientId)
            subscriptionType = try? container.decodeIfPresent(
                String.self, forKey: .subscriptionType)
            rateLimitTier = try? container.decodeIfPresent(String.self, forKey: .rateLimitTier)
        }
    }
}

/// Accepts `expiresAt` as either a JSON number or a numeric string; observed as a
/// number, but a string form would otherwise fail the whole decode.
private struct EpochMilliseconds: Decodable {
    let milliseconds: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            milliseconds = value
            return
        }
        if let text = try? container.decode(String.self), let value = Double(text) {
            milliseconds = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "`expiresAt` is not a number")
    }
}
