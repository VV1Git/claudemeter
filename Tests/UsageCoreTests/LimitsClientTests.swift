import Foundation
import Testing

import UsageCore

/// Answers every request from memory, so no test in this file opens a socket.
private final class LimitsClientStubURLProtocol: URLProtocol {
    private struct Canned {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: Canned?
    nonisolated(unsafe) private static var recorded: URLRequest?

    static func set(status: Int, headers: [String: String] = [:], body: Data) {
        lock.lock()
        defer { lock.unlock() }
        canned = Canned(status: status, headers: headers, body: body)
        recorded = nil
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        canned = nil
        recorded = nil
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LimitsClientStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded = request
        let canned = Self.canned ?? Canned(status: 200, headers: [:], body: Data())
        Self.lock.unlock()

        guard let client else { return }
        if let response = HTTPURLResponse(
            url: request.url ?? LimitsClient.endpoint,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: canned.headers)
        {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocol(self, didLoad: canned.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized because the fetch tests share one `URLProtocol` stub; nothing here
/// touches the network, the Keychain, or the filesystem outside the test bundle.
@Suite(.serialized)
struct LimitsClientTests {

    private typealias Stub = LimitsClientStubURLProtocol

    // MARK: - Fixtures

    private struct MissingFixture: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture \(name).json is not in the test bundle" }
    }

    private static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else { throw MissingFixture(name: name) }
        return try Data(contentsOf: url)
    }

    private static func fullSnapshot(fetchedAt: Date = Date(timeIntervalSince1970: 1_768_501_000))
        throws -> UsageSnapshot
    {
        try LimitsClient.decodeSnapshot(from: fixture("usage-response"), fetchedAt: fetchedAt)
    }

    private static func sparseSnapshot(fetchedAt: Date = Date(timeIntervalSince1970: 1_768_501_000))
        throws -> UsageSnapshot
    {
        try LimitsClient.decodeSnapshot(
            from: fixture("usage-response-sparse"), fetchedAt: fetchedAt)
    }

    // MARK: - Full payload

    @Test func decodesBothWindowsFromTheFullPayload() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_768_501_100)
        let snapshot = try Self.fullSnapshot(fetchedAt: fetchedAt)

        #expect(snapshot.fiveHour?.utilization == 42)
        #expect(snapshot.sevenDay?.utilization == 13)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func fullPayloadHasThreeLimitsAndDisabledExtraUsage() throws {
        let snapshot = try Self.fullSnapshot()

        #expect(snapshot.limits.count == 3)
        #expect(snapshot.limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(snapshot.extraUsage?.isEnabled == false)

        let extra = try #require(snapshot.extraUsage)
        #expect(extra.utilization == nil)
        #expect(extra.spendLimitReached == false)
    }

    @Test func fullPayloadScopedWeeklyLimitIsLabelled() throws {
        let snapshot = try Self.fullSnapshot()
        let scoped = snapshot.scopedWeeklyLimits

        #expect(scoped.count == 1)
        let scopedLimit = try #require(scoped.first)
        #expect(scopedLimit.scopeLabel == "Opus")
        #expect(scopedLimit.percent == 0)
        #expect(scopedLimit.isActive == false)
        // `scope` is null on the other two entries, so no label leaks onto them.
        #expect(snapshot.limits.compactMap(\.scopeLabel) == ["Opus"])
    }

    @Test func fullPayloadParsesSixDigitFractionWithNumericOffset() throws {
        let snapshot = try Self.fullSnapshot()

        let fiveHourReset = try #require(snapshot.fiveHour?.resetsAt)
        #expect(abs(fiveHourReset.timeIntervalSince1970 - 1_768_501_800.123456) < 0.001)

        let sevenDayReset = try #require(snapshot.sevenDay?.resetsAt)
        #expect(abs(sevenDayReset.timeIntervalSince1970 - 1_768_712_400.123456) < 0.001)

        // The scoped entry has a null reset, which must stay nil rather than 1970.
        let scoped = try #require(snapshot.scopedWeeklyLimits.first)
        #expect(scoped.resetsAt == nil)
    }

    @Test func fullPayloadMostConstrainedIsTheFiveHourWindow() throws {
        let snapshot = try Self.fullSnapshot()
        let constrained = try #require(snapshot.mostConstrained)

        #expect(constrained.kind == .fiveHour)
        #expect(constrained.window.utilization == 42)
    }

    // MARK: - Sparse (hostile) capture

    @Test func sparseCaptureDecodesWithoutThrowing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_768_700_000)
        let snapshot = try Self.sparseSnapshot(fetchedAt: fetchedAt)

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.utilization == 93.5)
        #expect(snapshot.extraUsage == nil)
        #expect(snapshot.limits.count == 3)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func sparseCaptureParsesZuluTimestampWithNoFractionalSeconds() throws {
        let snapshot = try Self.sparseSnapshot()
        let reset = try #require(snapshot.sevenDay?.resetsAt)

        #expect(reset == Date(timeIntervalSince1970: 1_768_712_400))
    }

    @Test func sparseCaptureUnknownSeverityFallsBackToPercent() throws {
        let snapshot = try Self.sparseSnapshot()
        let unknown = try #require(
            snapshot.limits.first { $0.kind == "some_future_kind_we_have_never_seen" })

        #expect(unknown.percent == 12)
        #expect(unknown.severity == .normal)
        #expect(unknown.severity == Severity.fromPercent(12))
    }

    @Test func sparseCaptureKeepsUnknownKindAndGroupAsStrings() throws {
        let snapshot = try Self.sparseSnapshot()
        let unknown = try #require(snapshot.limits.last)

        #expect(unknown.kind == "some_future_kind_we_have_never_seen")
        #expect(unknown.group == "unknown_group")
        #expect(unknown.isActive == false)
    }

    @Test func sparseCaptureKeepsRecognisedSeverities() throws {
        let snapshot = try Self.sparseSnapshot()

        #expect(snapshot.limits.first?.severity == .critical)
        #expect(snapshot.limits.first(where: { $0.kind == "weekly_scoped" })?.severity == .warning)
    }

    @Test func sparseCaptureScopedWeeklyFindsOpus() throws {
        let snapshot = try Self.sparseSnapshot()
        let scoped = snapshot.scopedWeeklyLimits

        #expect(scoped.count == 1)
        let opus = try #require(scoped.first)
        #expect(opus.scopeLabel == "Opus")
        #expect(opus.percent == 41.25)
        #expect(opus.isActive)
    }

    @Test func sparseCaptureMostConstrainedIsTheSevenDayWindow() throws {
        let snapshot = try Self.sparseSnapshot()
        let constrained = try #require(snapshot.mostConstrained)

        #expect(constrained.kind == .sevenDay)
        #expect(constrained.window.utilization == 93.5)
    }

    // MARK: - Decode tolerance

    @Test func emptyObjectDecodesToAnEmptySnapshot() throws {
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data("{}".utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.extraUsage == nil)
        #expect(snapshot.mostConstrained == nil)
    }

    @Test func malformedLimitsEntryIsSkippedRatherThanFailingTheDecode() throws {
        let json = """
        {
          "five_hour": {"utilization": 4.5, "resets_at": "nonsense"},
          "limits": [
            {"kind": "session", "group": "session", "percent": "not-a-number"},
            {"kind": "weekly_all", "group": "weekly", "percent": 4.5, "is_active": true}
          ]
        }
        """
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        let window = try #require(snapshot.fiveHour)
        #expect(window.utilization == 4.5)
        // An unparseable `resets_at` degrades to nil instead of failing the read.
        #expect(window.resetsAt == nil)
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits.first?.kind == "weekly_all")
    }

    @Test func malformedTopLevelFieldDoesNotVoidTheRestOfTheSnapshot() throws {
        // `extra_usage` is decoration and `seven_day` is secondary; neither is
        // allowed to take the five-hour percentage down with it.
        let json = """
        {
          "five_hour": {"utilization": 42.0, "resets_at": "2026-01-15T18:30:00.123456+00:00"},
          "seven_day": 42,
          "extra_usage": {"is_enabled": "nope"},
          "limits": {"not": "an array"}
        }
        """
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        #expect(snapshot.fiveHour?.utilization == 42)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.extraUsage == nil)
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.mostConstrained?.kind == .fiveHour)
    }

    /// A fabricated 0% would claim headroom we cannot actually see — and worse, it
    /// would win `mostConstrained` and put "0%" in the menu bar. Unreadable is not
    /// the same as empty, so every way of failing to read a percentage drops the
    /// window and the caller keeps serving the cached snapshot.
    @Test(arguments: [
        #"{"utilization": "42"}"#,   // wrong type
        #"{"utilization": null}"#,   // explicitly null
        #"{"resets_at": "2026-01-18T05:00:00Z"}"#,  // key absent
        "{}",
    ])
    func unreadableWindowIsDroppedRatherThanReportedAsZero(window: String) throws {
        let json = #"{"five_hour": \#(window), "seven_day": {"utilization": 3}}"#
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.utilization == 3)
        // The readable window is the one that gets surfaced, not a phantom 0%.
        #expect(snapshot.mostConstrained?.kind == .sevenDay)
    }

    /// The mirror of the rule above: `resets_at` is decoration next to the
    /// percentage, so a timestamp that is unparseable *or* the wrong type degrades
    /// to nil instead of taking the whole window down with it.
    @Test(arguments: ["\"nonsense\"", "99", "{\"at\": 1}", "null"])
    func unreadableResetsAtKeepsTheWindowPercentage(resetsAt: String) throws {
        let json = #"{"five_hour": {"utilization": 4.5, "resets_at": \#(resetsAt)}}"#
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        let window = try #require(snapshot.fiveHour)
        #expect(window.utilization == 4.5)
        #expect(window.resetsAt == nil)
    }

    @Test func nullAndNonObjectLimitsEntriesAreSkipped() throws {
        let json = """
        {"limits": [null, "weekly", [1], {"kind": "weekly_all", "group": "weekly",
         "percent": 93.5, "severity": "critical", "is_active": true}]}
        """
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits.first?.kind == "weekly_all")
        #expect(snapshot.limits.first?.severity == .critical)
    }

    @Test func limitEntrySurvivesMalformedAuxiliaryFields() throws {
        // Only `percent` is worth failing a row over — a `scope` or `is_active`
        // that changes shape must not lose us the API's own severity.
        let json = """
        {"limits": [{"kind": "weekly_all", "group": "weekly", "percent": 93.5,
          "severity": "critical", "is_active": "yes", "scope": "model", "resets_at": 99}]}
        """
        let snapshot = try LimitsClient.decodeSnapshot(
            from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

        let limit = try #require(snapshot.limits.first)
        #expect(limit.percent == 93.5)
        #expect(limit.severity == .critical)
        #expect(limit.isActive == false)
        #expect(limit.scopeLabel == nil)
        #expect(limit.resetsAt == nil)
    }

    /// `scopeLabel` is the *nested* `scope.model.display_name`, so it only works if
    /// the DTO maps that key explicitly. Every other shape of `scope` has to read as
    /// "no label" rather than throwing.
    @Test func scopeLabelComesFromTheNestedModelDisplayName() throws {
        let cases: [(scope: String, expected: String?)] = [
            (#"{"model": {"id": "claude-opus-5", "display_name": "Opus"}, "surface": null}"#, "Opus"),
            (#"{"model": {"display_name": "Haiku"}}"#, "Haiku"),
            (#"{"model": {"id": "claude-opus-5"}, "surface": null}"#, nil),
            (#"{"model": {"display_name": null}}"#, nil),
            (#"{"model": null, "surface": "web"}"#, nil),
            ("null", nil),
            ("{}", nil),
            (#""weekly_scoped""#, nil),
        ]
        for (scope, expected) in cases {
            let json = #"""
            {"limits": [{"kind": "weekly_scoped", "group": "weekly", "percent": 41.25,
              "scope": \#(scope)}]}
            """#
            let snapshot = try LimitsClient.decodeSnapshot(
                from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

            #expect(snapshot.scopedWeeklyLimits.count == 1, "scope \(scope) dropped the entry")
            #expect(snapshot.limits.first?.scopeLabel == expected, "scope \(scope)")
        }
    }

    @Test func severityStringsAreDecodedTolerantly() throws {
        // `Severity` is a String-raw-value enum, so decoding it directly would
        // throw on anything new. Percent is 12 throughout, so a fallback shows up
        // as `.normal` and a respected string does not.
        let cases: [(raw: String, expected: Severity)] = [
            (#""unrecognised_severity_value""#, .normal),
            (#""""#, .normal),
            (#""normal""#, .normal),
            (#""CRITICAL""#, .critical),
            (#"" warning ""#, .warning),
            // Not even a string any more: still classified, still not thrown.
            ("3", .normal),
            ("null", .normal),
            ("{}", .normal),
        ]
        for (raw, expected) in cases {
            let json = """
            {"limits": [{"kind": "k", "group": "g", "percent": 12, "severity": \(raw)}]}
            """
            let snapshot = try LimitsClient.decodeSnapshot(
                from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100))

            #expect(snapshot.limits.count == 1, "severity \(raw) dropped the entry")
            #expect(snapshot.limits.first?.severity == expected, "severity \(raw)")
        }
    }

    @Test func garbageBodyThrowsDecodingError() throws {
        do {
            _ = try LimitsClient.decodeSnapshot(
                from: Data("this is not JSON".utf8), fetchedAt: Date())
            Issue.record("expected a decoding failure")
        } catch let error as LimitsClientError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    // MARK: - HTTP behaviour (fully stubbed, no network)

    @Test func endpointIsTheOAuthUsagePath() {
        #expect(
            LimitsClient.endpoint.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    }

    @Test func fetchSendsOnlyBearerAndAcceptHeaders() async throws {
        let body = try Self.fixture("usage-response")
        Stub.set(status: 200, body: body)
        defer { Stub.reset() }

        let now = Date(timeIntervalSince1970: 1_768_501_200)
        let snapshot = try await LimitsClient(session: Stub.session())
            .fetch(accessToken: "sk-test-token", now: now)

        #expect(snapshot.fiveHour?.utilization == 42)
        #expect(snapshot.fetchedAt == now)

        let request = try #require(Stub.lastRequest())
        #expect(request.httpMethod == "GET")
        #expect(request.url == LimitsClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Verified against the live endpoint: no beta header is required, so none is sent.
        let headerNames = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        #expect(!headerNames.contains("anthropic-beta"))
    }

    @Test(arguments: [401, 403])
    func fetchMapsAuthFailuresToUnauthorized(status: Int) async throws {
        Stub.set(status: status, body: Data("{}".utf8))
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        await #expect(throws: LimitsClientError.unauthorized) {
            _ = try await client.fetch(accessToken: "tok")
        }
    }

    @Test func fetchParsesRetryAfterSecondsOn429() async throws {
        Stub.set(status: 429, headers: ["Retry-After": "30"], body: Data())
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        await #expect(throws: LimitsClientError.rateLimited(retryAfter: 30)) {
            _ = try await client.fetch(accessToken: "tok")
        }
    }

    @Test func fetchTolerates429WithNoRetryAfterHeader() async throws {
        Stub.set(status: 429, body: Data())
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        await #expect(throws: LimitsClientError.rateLimited(retryAfter: nil)) {
            _ = try await client.fetch(accessToken: "tok")
        }
    }

    /// `TimeInterval(_:)` happily parses `"nan"`, `"inf"`, `"1e400"` and `"-5"`.
    /// Any of those reaching `retryAfter` would give the caller a backoff it cannot
    /// schedule, and NaN additionally breaks `Equatable` on the error. A malformed
    /// header must read the same as a missing one.
    @Test(arguments: [
        "Fri, 31 Dec 1999 23:59:59 GMT", "later", "30, 60", "-5", "nan", "inf", "1e400",
    ])
    func fetchTreatsAnUnusableRetryAfterAsAbsent(header: String) async throws {
        Stub.set(status: 429, headers: ["Retry-After": header], body: Data())
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        await #expect(throws: LimitsClientError.rateLimited(retryAfter: nil)) {
            _ = try await client.fetch(accessToken: "tok")
        }
    }

    // 0 is in this list because the live endpoint sends `Retry-After: 0`, and it must read the
    // same as an absent header rather than promising a retry that will not happen for a minute.
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -5, 0])
    func rateLimitedDescriptionDropsAnUnusableRetryAfter(seconds: Double) {
        // `Int(_:)` traps on these, and the associated value is public.
        #expect(LimitsClientError.rateLimited(retryAfter: seconds).description == "Rate limited")
    }

    @Test func rateLimitedDescriptionCapsAnAbsurdRetryAfter() {
        #expect(
            LimitsClientError.rateLimited(retryAfter: 30).description
                == "Rate limited — retry in 30s")
        #expect(
            LimitsClientError.rateLimited(retryAfter: 1e300).description
                == "Rate limited — retry in 86400s")
    }

    @Test func fetchMapsOtherFailuresToHTTPStatus() async throws {
        Stub.set(status: 503, body: Data())
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        await #expect(throws: LimitsClientError.httpStatus(503)) {
            _ = try await client.fetch(accessToken: "tok")
        }
    }

    @Test func fetchMapsUndecodableSuccessBodyToDecodingError() async throws {
        Stub.set(status: 200, body: Data("<html>nope</html>".utf8))
        defer { Stub.reset() }

        let client = LimitsClient(session: Stub.session())
        do {
            _ = try await client.fetch(accessToken: "tok")
            Issue.record("expected a decoding failure")
        } catch let error as LimitsClientError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }
}
