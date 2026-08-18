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
    /// The item is there and this app is not currently allowed to decrypt it: the partition list
    /// no longer admits this build, and answering would mean a login-password dialog.
    ///
    /// Its own case rather than an `.unhandled` status because it is the one failure the user can
    /// clear, and the only correct response is to offer them the choice — never to raise the
    /// dialog behind their back. See `readCredentials(interactive:)`.
    case accessDenied
    /// The user dismissed the authorization dialog they were shown. Distinct from `.accessDenied`,
    /// which is what happens when no dialog was permitted in the first place: a refusal is an
    /// answer, and re-asking immediately would be badgering.
    case authorizationCancelled
    /// Any other `SecItemCopyMatching` result.
    case unhandled(OSStatus)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials found in the Keychain."
        case .malformed(let detail):
            return "Claude Code credentials could not be read: \(detail)"
        case .accessDenied:
            return "ClaudeMeter is not currently allowed to read Claude Code's credentials."
        case .authorizationCancelled:
            return "Keychain authorization was cancelled."
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain access failed: \(message)"
        }
    }

    /// Whether re-reading might succeed once the user has authorized it. `AppModel` uses this to
    /// decide between offering an Authorize button and reporting a fault.
    public var isAuthorizationProblem: Bool {
        switch self {
        case .accessDenied, .authorizationCancelled:
            return true
        case .notFound, .malformed, .unhandled:
            return false
        }
    }
}

// MARK: - Keychain access

/// Access to the credential item Claude Code stores.
///
/// **This app never writes this item.** That is a design rule, not a default, and it is the
/// single thing keeping ClaudeMeter from breaking the CLI it reads from.
///
/// Two facts force it. Changing an item's data makes securityd build the item a fresh storage
/// group, and a fresh group carries a partition list holding exactly one identity — the
/// writer's. Every other identity is evicted. Measured on macOS 15 against a throwaway item
/// seeded with three identities, both `SecItemUpdate` and the legacy
/// `SecKeychainItemModifyContent` collapsed the list to the writer alone, so there is no API
/// that writes and leaves the list intact. And renewing a token means spending Claude Code's
/// refresh token, which the endpoint rotates: the CLI's stored copy dies the instant this app
/// spends it, so a renewal this app cannot persist signs the user out of Claude Code.
///
/// Writing would therefore lock the CLI out of its own credential, and not writing after a
/// renewal would sign it out. Declining to renew at all is the only branch that does neither,
/// so this type reads and nothing more. Reads leave the partition list untouched.
///
/// What the app *may* own is a credential of its own — `ownService`, an item this app creates
/// and is the only writer of. Nothing evicts anybody there, because nobody else touches it.
///
/// `partitionIdentities()` reports what the shared item's list holds, so the panel can tell the
/// user when a write from some *earlier* build of this app left the CLI locked out.
public enum Keychain {
    public static let service = "Claude Code-credentials"

    /// ClaudeMeter's own credential item, for a token the user has dedicated to this app (see
    /// `claude setup-token`). Created and written by this app alone, so its partition list holds
    /// this app's identity from birth and no other process ever resets it — which is why the
    /// dedicated-token path raises no dialogs at all.
    public static let ownService = "com.claudemeter.ClaudeMeter-credentials"
    public static let ownAccount = "claudemeter"

    /// The partition identity the Claude Code CLI reads under. It goes through
    /// `/usr/bin/security`, an Apple-signed tool, so securityd files it under the tool
    /// identity rather than a team.
    public static let cliPartitionIdentity = "apple-tool:"

    /// The partition identity this app reads under, derived from the signature of the code that
    /// is actually running, or `nil` when that signature cannot be read.
    ///
    /// Deliberately not a constant. The identity depends on how the copy in front of the user was
    /// built: a Developer ID or Apple Development signature is filed under its team, an ad-hoc
    /// signature under the code directory hash of that one build, and an unsigned build under
    /// `unsigned:`. Hard-coding this project's team would hand every other build a repair command
    /// that *replaces* the partition list with an identity it does not have — locking the running
    /// app out of the item in the act of unlocking the CLI. `nil` is why the repair command is
    /// optional: no command at all is better than a wrong one.
    ///
    /// Resolved once. A process cannot change its own signature while it runs, and the panel row
    /// that shows the repair re-evaluates on every layout pass.
    public static let appPartitionIdentity: String? = resolveAppPartitionIdentity()

    private static func resolveAppPartitionIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }

        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return unsignedPartitionIdentity }
        guard status == errSecSuccess, let information = information as? [String: Any] else {
            return nil
        }

        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "teamid:\(team)"
        }
        // No team means an ad-hoc signature, which leaves the code directory hash as the only
        // identifier the build has — and a different one after every rebuild. The value is the
        // truncated hash `codesign -dvvv` prints as `CDHash=`, lowercase hex.
        if let unique = information[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty {
            return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
        }
        // A dictionary carrying neither is what a completely unsigned binary looks like: the call
        // succeeds and hands back nothing but the executable's path. Verified rather than assumed
        // — an unsigned build does not report `errSecCSUnsigned` through this entry point, so
        // relying on that status alone would answer "unknown" for the one case that has a
        // perfectly well-defined partition identity.
        return unsignedPartitionIdentity
    }

    /// What securityd files code with no signature under.
    private static let unsignedPartitionIdentity = "unsigned:"

    /// The single line that puts both this app and the CLI back on the item's partition list, for
    /// the panel to offer when it notices one has been evicted.
    ///
    /// The list it names is the one on the item now plus whichever of the two is missing, never
    /// just the two: `-S` replaces the list outright, so naming only the identities this app cares
    /// about would quietly revoke any third program that has been granted access. `nil` on either
    /// of the two questions this cannot answer — the identity of the running build, and what the
    /// list currently holds — because a replace built on a guess is how a repair evicts the app
    /// that offered it.
    public static var partitionRepairCommand: String? {
        guard let appPartitionIdentity, var identities = partitionIdentities() else { return nil }
        for required in [cliPartitionIdentity, appPartitionIdentity]
        where !identities.contains(required) {
            identities.append(required)
        }
        return partitionRepairCommand(
            admitting: identities, account: itemAccount() ?? NSUserName())
    }

    /// The shared item's `acct` attribute, so the repair command names the item that is really
    /// there rather than assuming it was written under the current short user name. Attributes
    /// only — no `kSecReturnData` — so nothing is decrypted and no dialog can be raised.
    static func itemAccount() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let attributes = item as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccount as String] as? String
    }

    /// Run by the user in a terminal, deliberately, because `security` prompts for the login
    /// password through `getpass` there and nothing kills it mid-typing — unlike the dialogs the
    /// CLI's own two-second read timeout tears down. `-S` replaces the list rather than merging
    /// into it, which is why every identity that is to survive has to be named in one command,
    /// and there is no `-k`: a password on the command line would land in shell history.
    public static func partitionRepairCommand(
        admitting identities: [String], account: String = NSUserName()
    ) -> String {
        // Every interpolated field is single-quoted, the account included. It comes from the
        // item's stored `acct` attribute rather than from anything this app chose, and nothing
        // guarantees it is a bare short name — a space in it would split the argument and point
        // `-S` at some other item. That matters more here than in most commands, because `-S`
        // *replaces* a partition list rather than adding to one, so a mis-parsed invocation
        // revokes access somewhere instead of failing harmlessly.
        "security set-generic-password-partition-list "
            + "-S '\(identities.joined(separator: ","))' "
            + "-s '\(service)' -a '\(account)' ~/Library/Keychains/login.keychain-db"
    }

    /// Reads and parses Claude Code's credential item.
    ///
    /// `interactive` is the whole ergonomics of this app's Keychain story. Claude Code rewrites
    /// this item every time it renews, which resets the partition list to `apple-tool:` and
    /// evicts this app — so a read that is allowed to prompt will, sooner or later, raise a
    /// login-password dialog. Raised from a poll, that dialog is modal, unannounced, and blocks
    /// whatever thread asked for it.
    ///
    /// So the polling path passes `false` and takes `.accessDenied` for an answer, and the panel
    /// offers the user a button. Only that button passes `true`, at a moment the user is
    /// expecting a dialog because they just asked for one.
    public static func readCredentials(interactive: Bool = false) throws -> ClaudeCredentials {
        try parseCredentials(from: readItemData(service: service, interactive: interactive))
    }

    /// Raw item data, before any interpretation.
    private static func readItemData(service: String, interactive: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Belt and braces: the modern flag is what `SecItem` honours, and the legacy switch is
        // what the ACL prompt on a legacy keychain item honours. The credential item is a legacy
        // item, so the second one is the one that actually does the work here — but the flag
        // costs nothing and covers a future item that is not.
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = withUserInteraction(interactive) {
            SecItemCopyMatching(query as CFDictionary, &item)
        }

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.malformed("Keychain item carried no data")
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecUserCanceled:
            throw KeychainError.authorizationCancelled
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// When the item was last changed, read from attributes alone.
    ///
    /// The cheap half of the whole credential story: attributes are not encrypted, so this
    /// decrypts nothing, needs no authorization and cannot raise a dialog even when the partition
    /// list has evicted this app. That makes it safe to call on a schedule, which is what lets
    /// `CredentialStore` hold one decrypted credential in memory for hours and still notice the
    /// moment Claude Code renews — without a single further read of the payload.
    ///
    /// `nil` when there is no item, or when the attribute is missing.
    public static func modificationDate(service: String = Keychain.service) -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let attributes = item as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Runs `body` with legacy Keychain dialogs suppressed unless `interactive`.
    ///
    /// `SecKeychainSetUserInteractionAllowed` is process-global, which would be a hazard if two
    /// threads used it at once. They cannot: every call into this type goes through
    /// `CredentialStore`, an actor, so these are serialised. The previous setting is restored
    /// rather than assumed, so an interactive read cannot leave the process able to prompt.
    private static func withUserInteraction<T>(_ interactive: Bool, _ body: () -> T) -> T {
        var previous: DarwinBoolean = true
        let queried = SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess
        SecKeychainSetUserInteractionAllowed(interactive)
        defer { SecKeychainSetUserInteractionAllowed(queried ? previous.boolValue : true) }
        return body()
    }

    // MARK: - This app's own credential

    /// Reads the token the user dedicated to ClaudeMeter, or `nil` when there is none.
    ///
    /// No `interactive` parameter, because the question never arises: this app created the item,
    /// this app is the only writer, and nothing else on the machine resets its partition list.
    /// An error here is a real fault rather than a permission to negotiate, so a missing or
    /// unreadable item simply reads as "no dedicated token" and the shared item is used instead.
    public static func readOwnCredentials() -> ClaudeCredentials? {
        guard let data = try? readItemData(service: ownService, interactive: false) else {
            return nil
        }
        return try? parseCredentials(from: data)
    }

    /// Writes this app's own credential, creating the item if it is not there yet.
    ///
    /// Stored in Claude Code's own JSON shape rather than a private one, so the same parser reads
    /// both and a dedicated token is not a second credential format to keep working.
    public static func storeOwnCredentials(_ credentials: ClaudeCredentials) throws {
        let encoded = try encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]

        let update = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: encoded] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.unhandled(update) }

        var insert = query
        insert[kSecValueData as String] = encoded
        // Readable whenever the keychain is unlocked, and never synced to other devices: the
        // token is machine-local by nature and iCloud Keychain would put it somewhere this app
        // cannot reason about.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        insert[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.unhandled(added) }
    }

    /// Forgets this app's own credential. Not an error when there was none.
    public static func deleteOwnCredentials() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ownService,
                kSecAttrAccount as String: ownAccount,
            ] as CFDictionary)
    }

    private static let oauthKey = "claudeAiOauth"

    /// `ClaudeCredentials` in the CLI's storage shape, so `parseCredentials` reads it back.
    /// Exposed for tests, which round-trip it rather than trusting the two halves to agree.
    public static func encode(_ credentials: ClaudeCredentials) throws -> Data {
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken,
            "expiresAt": epochMilliseconds(credentials.expiresAt),
        ]
        if let refreshToken = credentials.refreshToken { oauth["refreshToken"] = refreshToken }
        if let deadline = credentials.refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = epochMilliseconds(deadline)
        }
        if !credentials.scopes.isEmpty { oauth["scopes"] = credentials.scopes }
        if let clientID = credentials.clientID { oauth["clientId"] = clientID }
        if let plan = credentials.subscriptionType { oauth["subscriptionType"] = plan }
        if let tier = credentials.rateLimitTier { oauth["rateLimitTier"] = tier }

        do {
            return try JSONSerialization.data(withJSONObject: [oauthKey: oauth])
        } catch {
            throw KeychainError.malformed("Credentials could not be encoded")
        }
    }

    /// The CLI stores deadlines as epoch milliseconds, and as whole numbers.
    ///
    /// Rounded *up*, not to nearest. A `Date` carries more precision than the field does, so
    /// something has to give; giving it upwards means a stored deadline is never earlier than the
    /// one handed in, and a write-then-read of a credential can only ever move expiry later. To
    /// nearest, the same round trip could retire a token up to half a millisecond early. Nothing
    /// downstream would notice half a millisecond — the lead time is five minutes — but "expiry
    /// never moves backwards through storage" is a property worth being able to state without
    /// qualification, and it costs one function call.
    private static func epochMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded(.up))
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

// MARK: - Partition list

extension Keychain {
    /// Which identities the shared item's partition list currently admits, or `nil` when that
    /// could not be determined.
    ///
    /// Nothing here decrypts the item: an ACL is copied without authorization, which is why
    /// `security dump-keychain -a` reads every item on the machine without raising a single
    /// dialog. `kSecReturnRef` is used rather than `kSecReturnData` for exactly that reason, and
    /// this is the one Keychain call in the app that is safe to make on a schedule.
    ///
    /// The distinction between `nil` and `[]` is the whole safety property of the return type. An
    /// empty list means the item admits nobody, which is a real and reportable state; `nil` means
    /// the question went unanswered, and must never be rendered as an answer.
    ///
    /// The legacy `SecKeychain*` calls below warn on sight: they were deprecated with the rest of
    /// the legacy Keychain API in 10.10 and never replaced. Partition lists exist only on legacy
    /// keychain items, the modern `SecItem` API cannot see an ACL at all, and these are the same
    /// entry points `/usr/bin/security` uses to print one. The warnings are the price of asking
    /// a question that only the old API can answer.
    public static func partitionIdentities() -> [String]? {
        // The same predicate the credential read uses, so the list reported here is the list on
        // the item this app actually polls with. Naming an account instead would let the two
        // diverge and turn a real lockout into a silent "unknown".
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        // Conditionally cast rather than forced: `kSecReturnRef` on a generic password hands back
        // a legacy keychain item today, and a build that ever gets something else back must
        // answer "unknown" rather than trap in a menu bar app.
        var match: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &match) == errSecSuccess,
            let match, CFGetTypeID(match) == SecKeychainItemGetTypeID()
        else { return nil }
        let item = unsafeBitCast(match, to: SecKeychainItem.self)

        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else {
            return nil
        }

        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess,
            let acls = list as? [SecACL]
        else { return nil }

        // The partition list lives in the description of the one ACL entry carrying the
        // partition authorization. Every other entry describes who may decrypt or change the
        // item, which is a different question.
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains(kSecACLAuthorizationPartitionID as String) else {
                continue
            }
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess,
                let description = description as String?
            else { return nil }
            return partitionIdentities(fromACLDescription: description)
        }
        return nil
    }

    /// Reads the identities out of a partition ACL's description string.
    ///
    /// The description is not the tidy `teamid:X, apple-tool:` line `security dump-keychain`
    /// prints — that is the tool's own summary. What is stored is an XML plist whose
    /// `Partitions` key holds an array of identity strings, and it arrives hex-encoded, because
    /// the field is nominally human-readable text and plist bytes are not. Both forms are
    /// accepted: the hex is decoded first, and a description that is already plist bytes is
    /// parsed as it stands, so a future macOS that stops encoding the field cannot silently turn
    /// this into a function that always answers "unknown".
    ///
    /// Split out from the Security-framework half so the parse — the part that can be wrong in a
    /// way no status code reports — is testable without a Keychain.
    public static func partitionIdentities(fromACLDescription description: String) -> [String]? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bytes = hexDecoded(trimmed) ?? Data(trimmed.utf8)
        guard
            let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
                as? [String: Any],
            let partitions = plist["Partitions"] as? [String]
        else { return nil }
        return partitions
    }

    /// `nil` for anything that is not a whole number of hex bytes, which is how a description
    /// holding plain plist bytes is told apart from an encoded one.
    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Whether the partition list locks Claude Code out of the item it owns.
    ///
    /// An unanswered question is not a lockout: `nil` reports false, so a machine where the ACL
    /// cannot be read never shows a warning telling the user to repair something that may well
    /// be fine.
    public static func isCLILockedOut(partitions: [String]?) -> Bool {
        guard let partitions else { return false }
        return !partitions.contains(cliPartitionIdentity)
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
