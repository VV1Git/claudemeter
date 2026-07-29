import Foundation
import Security

// MARK: - Credentials

/// The subset of the Claude Code credential item this app needs.
///
/// Only the access token and its metadata are carried: the refresh token is
/// deliberately dropped, because this app never refreshes — it reads whatever
/// Claude Code last wrote and reports staleness instead of racing the CLI for
/// token rotation.
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date
    /// `"max"` on the observed machine. Absent on credential shapes that predate the field.
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String, expiresAt: Date, subscriptionType: String?, rateLimitTier: String?
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// Expiry is treated as inclusive: a token whose deadline is exactly `now` is
    /// already unusable, since the request would land after it.
    public func isExpired(asOf now: Date) -> Bool {
        expiresAt <= now
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

/// Read-only access to the credential item Claude Code stores.
///
/// Nothing here writes, updates, or deletes: this app is a passive observer of the
/// CLI's login state, and a write would risk clobbering a token the CLI just rotated.
public enum Keychain {
    public static let service = "Claude Code-credentials"

    /// Reads and parses the credential item. Read-only: never writes or refreshes.
    public static func readCredentials() throws -> ClaudeCredentials {
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
            return try parseCredentials(from: data)
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.unhandled(status)
        }
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
            // `expiresAt` is epoch milliseconds (e.g. 1700000000000), not seconds.
            expiresAt: Date(timeIntervalSince1970: expiry.milliseconds / 1000),
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
        let subscriptionType: String?
        let rateLimitTier: String?
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
