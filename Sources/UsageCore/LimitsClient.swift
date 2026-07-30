import Foundation

// MARK: - Errors

/// Why a single read of the usage endpoint failed.
///
/// The cases are kept apart because the app reacts differently to each:
/// `.unauthorized` means re-read the Keychain for a token Claude Code has since
/// refreshed, `.rateLimited` means back off for `retryAfter`, and transport or
/// decoding failures only mean "keep serving the cached snapshot".
public enum LimitsClientError: Error, Sendable, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case transport(String)
    case decoding(String)
}

extension LimitsClientError: CustomStringConvertible {
    /// Short human-readable form, used as the `reason` of `DataHealth.offline`.
    public var description: String {
        switch self {
        case .unauthorized:
            return "Not authorized — credentials may have expired"
        case .rateLimited(let retryAfter):
            // `Int(_:)` traps on NaN, infinity and anything past `Int.max`, and the
            // associated value is public — a server sending `Retry-After: nan` or a
            // caller constructing the case by hand must not be able to kill the app.
            // `> 0`, not `>= 0`: this endpoint really does send `Retry-After: 0` when it
            // rate-limits, which means "no delay supplied", not "retry immediately". Rendering
            // that as "retry in 0s" contradicts the caller, which ignores a non-positive value
            // and falls back to its own backoff — so 0 reads as a bare "Rate limited".
            if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
                let seconds = Int(min(retryAfter.rounded(), 86_400))
                return "Rate limited — retry in \(seconds)s"
            }
            return "Rate limited"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .transport(let message):
            return message
        case .decoding(let message):
            return "Unexpected response: \(message)"
        }
    }
}

// MARK: - Client

/// Read-only client for `GET /api/oauth/usage`.
///
/// Verified against the live endpoint: a bearer token is the only header the
/// server requires, so no `anthropic-beta` header is sent. The client never
/// writes anything — token refresh is Claude Code's job, not this app's.
public struct LimitsClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(accessToken: String, now: Date = Date()) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LimitsClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LimitsClientError.transport("Response was not HTTP")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw LimitsClientError.unauthorized
        case 429:
            throw LimitsClientError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw LimitsClientError.httpStatus(http.statusCode)
        }

        return try Self.decodeSnapshot(from: data, fetchedAt: now)
    }

    /// Pure decode, exposed for fixture tests.
    public static func decodeSnapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let payload: UsagePayload
        do {
            payload = try JSONDecoder.claudeMeter().decode(UsagePayload.self, from: data)
        } catch {
            throw LimitsClientError.decoding(String(describing: error))
        }
        return payload.snapshot(fetchedAt: fetchedAt)
    }

    /// `Retry-After` in seconds. The endpoint sends the delta-seconds form; an
    /// HTTP-date is treated as absent rather than guessed at.
    ///
    /// Only a finite, non-negative value is reported. `TimeInterval("nan")`,
    /// `"inf"` and `"1e400"` all parse successfully in Swift, and a negative delay
    /// parses too — any of those would become a nonsense backoff, break
    /// `Equatable` on the error (`nan != nan`), and trap when formatted. A missing
    /// header and a malformed one are the same answer: we don't know, so the
    /// caller uses its own schedule.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }
}

// MARK: - Scoped limits

extension UsageSnapshot {
    /// Per-model weekly limits pulled out of `limits[]` (`kind == "weekly_scoped"`).
    /// These have no dedicated top-level window, so the generic array is the only
    /// place an Opus- or Fable-specific cap shows up.
    public var scopedWeeklyLimits: [RateLimit] {
        limits.filter { $0.kind == "weekly_scoped" }
    }
}

// MARK: - Wire DTOs

/// Wire format lives here, apart from the domain types, so the API is free to
/// grow keys the app has never seen without the models moving. Every field is
/// optional: a full payload nulls out most windows, and the sparse capture omits
/// whole objects.
private struct UsagePayload: Decodable {
    let fiveHour: WindowPayload?
    let sevenDay: WindowPayload?
    let extraUsage: ExtraUsagePayload?
    let limits: [LossyLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case extraUsage = "extra_usage"
        case limits
    }

    /// Each key is read independently: a type change in one of them (a `five_hour`
    /// that arrives as a number, an `extra_usage` with a string `is_enabled`, a
    /// `limits` that stops being an array) must not cost us the other windows.
    /// `extra_usage` in particular is decoration, and it used to be able to void
    /// the whole read. A body that isn't a JSON object still throws — that is a
    /// real failure and the caller should keep serving the cached snapshot.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? container.decodeIfPresent(WindowPayload.self, forKey: .fiveHour)
        sevenDay = try? container.decodeIfPresent(WindowPayload.self, forKey: .sevenDay)
        extraUsage = try? container.decodeIfPresent(ExtraUsagePayload.self, forKey: .extraUsage)
        limits = try? container.decodeIfPresent([LossyLimit].self, forKey: .limits)
    }

    func snapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour?.window,
            sevenDay: sevenDay?.window,
            limits: (limits ?? []).compactMap { $0.value?.rateLimit },
            extraUsage: extraUsage?.extraUsage,
            fetchedAt: fetchedAt
        )
    }
}

private struct WindowPayload: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Same split as `LimitPayload`, for the same reason. `utilization` is the only
    /// field worth failing the window over: `LimitWindow.utilization` is not
    /// optional, and substituting 0 would tell the user the window is empty when we
    /// simply could not read it — so a missing, null or non-numeric percentage drops
    /// the window and the caller falls back to the cached snapshot. `resets_at` is
    /// read independently: a timestamp that changes type must not cost us the
    /// percentage the menu bar actually shows.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decode(Double.self, forKey: .utilization)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }

    var window: LimitWindow {
        LimitWindow(
            utilization: utilization,
            resetsAt: resetsAt.flatMap(ISO8601.date(from:))
        )
    }
}

private struct LimitPayload: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: ScopePayload?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// `percent` is the one field worth failing over: `RateLimit.percent` is not
    /// optional, and inventing 0 would tell the user they have headroom they may
    /// not have — so an unreadable percent drops the row (see `LossyLimit`).
    /// Everything else is read independently, so a `scope` that changes shape or an
    /// `is_active` that arrives as `"yes"` costs only that field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
        severity = try? container.decodeIfPresent(String.self, forKey: .severity)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try? container.decodeIfPresent(ScopePayload.self, forKey: .scope)
        isActive = try? container.decodeIfPresent(Bool.self, forKey: .isActive)
    }

    var rateLimit: RateLimit {
        let pct = percent ?? 0
        return RateLimit(
            kind: kind ?? "",
            group: group ?? "",
            percent: pct,
            severity: Self.severity(from: severity, percent: pct),
            resetsAt: resetsAt.flatMap(ISO8601.date(from:)),
            scopeLabel: scope?.model?.displayName,
            isActive: isActive ?? false
        )
    }

    /// New severity strings ship before this app knows about them, so an
    /// unrecognised value is classified from the percentage instead of failing the
    /// whole decode. Case and surrounding whitespace are normalised first: a
    /// `"Critical"` that fell out of a casing change should still read as critical
    /// rather than silently dropping to whatever the percentage implies.
    private static func severity(from raw: String?, percent: Double) -> Severity {
        guard let raw else { return .fromPercent(percent) }
        let normalised = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Severity(rawValue: normalised) ?? .fromPercent(percent)
    }
}

private struct ScopePayload: Decodable {
    struct Model: Decodable {
        let id: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    let model: Model?
    let surface: String?
}

private struct ExtraUsagePayload: Decodable {
    let isEnabled: Bool?
    let utilization: Double?
    let spendLimitReached: Bool?

    enum CodingKeys: String, CodingKey {
        case utilization
        case isEnabled = "is_enabled"
        case spendLimitReached = "spend_limit_reached"
    }

    var extraUsage: ExtraUsage {
        ExtraUsage(
            isEnabled: isEnabled ?? false,
            utilization: utilization,
            spendLimitReached: spendLimitReached ?? false
        )
    }
}

/// Element wrapper that turns one undecodable `limits[]` entry into `nil` instead
/// of failing the whole array. A single malformed row — a `null` element, a
/// non-object, or a `percent` that is not a number — must not cost us the window
/// percentages, which are what the menu bar actually shows.
private struct LossyLimit: Decodable {
    let value: LimitPayload?

    init(from decoder: Decoder) throws {
        value = try? LimitPayload(from: decoder)
    }
}
