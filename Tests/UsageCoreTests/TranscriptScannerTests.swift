import Foundation
import Testing

@testable import UsageCore

/// `Paths.*Override` is process-global, so these tests must not run concurrently with each
/// other. They also resolve their file locations once, while the overrides are installed, and
/// pass them explicitly — a suite running in parallel elsewhere cannot then redirect a scanner
/// mid-test onto the real `~/.claude`.
@Suite(.serialized)
struct TranscriptScannerTests {

    // MARK: Dedup

    @Test("Three copies of one request collapse to one event carrying the field-wise max")
    func dedupTakesElementWiseMax() throws {
        try withTempEnvironment { env in
            let identical = try assistantRow(
                requestId: "req_1", messageId: "msg_1", input: 10, output: 100, cacheRead: 0)
            // Same key, larger payload — a streamed row followed by its final form.
            let larger = try assistantRow(
                requestId: "req_1", messageId: "msg_1", input: 10, output: 900, cacheRead: 5)
            try env.writeTranscript([identical, identical, larger], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.rawRowsSeen == 3)
            #expect(result.totalEventCount == 1)
            #expect(result.newEventCount == 1)
            #expect(result.inflationFactor == 3)

            let event = try #require(scanner.events.first)
            // Naive summing would report 1100 output tokens; first-wins would report 100.
            #expect(event.tokens.output == 900)
            #expect(event.tokens.input == 10)
            #expect(event.tokens.cacheRead == 5)
            #expect(event.key == "req_1|msg_1")
        }
    }

    @Test("dedupKey tolerates a missing requestId and keeps distinct messages apart")
    func dedupKeyShape() {
        #expect(TranscriptScanner.dedupKey(requestId: "req_1", messageId: "msg_1") == "req_1|msg_1")
        #expect(TranscriptScanner.dedupKey(requestId: nil, messageId: "msg_1") == "|msg_1")
        #expect(
            TranscriptScanner.dedupKey(requestId: nil, messageId: "msg_1")
                != TranscriptScanner.dedupKey(requestId: nil, messageId: "msg_2"))
    }

    @Test("Rows with a null or absent requestId are still keyed and counted")
    func nullRequestIdStillCounted() throws {
        try withTempEnvironment { env in
            let nullId = try assistantRow(requestId: nil, messageId: "msg_a", output: 1)
            let absentId = try assistantRow(
                requestId: nil, messageId: "msg_b", output: 2, omitRequestId: true)
            try env.writeTranscript([nullId, absentId], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.totalEventCount == 2)
            #expect(scanner.events.map(\.key) == ["|msg_a", "|msg_b"])
        }
    }

    // MARK: Filtering

    @Test("<synthetic> rows are excluded from events and from the raw row count")
    func syntheticExcluded() throws {
        try withTempEnvironment { env in
            let synthetic = try assistantRow(
                requestId: "req_s", messageId: "msg_s", model: "<synthetic>", output: 5000)
            let real = try assistantRow(requestId: "req_1", messageId: "msg_1", output: 7)
            try env.writeTranscript([synthetic, real], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.totalEventCount == 1)
            #expect(result.rawRowsSeen == 1)
            #expect(scanner.events.allSatisfy { $0.model != "<synthetic>" })
        }
    }

    @Test("Malformed, blank, non-assistant and usage-less lines are skipped, never fatal")
    func malformedLinesSkipped() throws {
        try withTempEnvironment { env in
            let usageless = #"{"type":"assistant","timestamp":"2026-07-11T23:10:08.208Z","message":{"id":"msg_x","model":"claude-sonnet-5"}}"#
            let lines = [
                "{not json at all",
                "",
                "[1,2,3]",
                #"{"type":"user","message":{"role":"user"}}"#,
                #"{"type":"file-history-snapshot"}"#,
                usageless,
                try assistantRow(requestId: "req_1", messageId: "msg_1", output: 42),
            ]
            try env.writeTranscript(lines, path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.rawRowsSeen == 1)
            #expect(scanner.events.count == 1)
            #expect(scanner.events.first?.tokens.output == 42)
        }
    }

    @Test("agentId and top-level effort are captured")
    func sidechainMetadataCaptured() throws {
        try withTempEnvironment { env in
            let sidechain = try assistantRow(
                requestId: "req_1", messageId: "msg_1", effort: "xhigh",
                isSidechain: true, agentId: "a19fd")
            let mainChain = try assistantRow(requestId: "req_2", messageId: "msg_2")
            try env.writeTranscript([sidechain, mainChain], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            try scanner.scan()

            let byKey = Dictionary(uniqueKeysWithValues: scanner.events.map { ($0.key, $0) })
            let agentEvent = try #require(byKey["req_1|msg_1"])
            #expect(agentEvent.agentId == "a19fd")
            #expect(agentEvent.isSidechain)
            #expect(agentEvent.effort == "xhigh")

            let plain = try #require(byKey["req_2|msg_2"])
            #expect(plain.agentId == nil)
            #expect(plain.effort == nil)
            #expect(plain.isSidechain == false)
        }
    }

    // MARK: Enumeration

    @Test("Nested directories are walked and non-jsonl files ignored")
    func recursiveEnumeration() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(requestId: "req_1", messageId: "msg_1")],
                path: "a/deep/nested/one.jsonl")
            try env.writeTranscript(
                [try assistantRow(requestId: "req_2", messageId: "msg_2")], path: "b/two.jsonl")
            try env.writeTranscript(
                [try assistantRow(requestId: "req_3", messageId: "msg_3")], path: "b/ignored.json")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.filesScanned == 2)
            #expect(result.totalEventCount == 2)
            #expect(scanner.events.map(\.key) == ["req_1|msg_1", "req_2|msg_2"])
        }
    }

    @Test("The default initialiser reads through the Paths overrides")
    func defaultsFollowPathsOverrides() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(requestId: "req_1", messageId: "msg_1")], path: "projA/a.jsonl")

            #expect(Paths.claudeProjects == env.root)
            #expect(Paths.scanStateFile == env.stateFile)
            #expect(Paths.eventCacheFile == env.cacheFile)

            let scanner = TranscriptScanner()   // default arguments resolve through `Paths`
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.totalEventCount == 1)
            try scanner.persistState()
            #expect(FileManager.default.fileExists(atPath: env.cacheFile.path))
            #expect(FileManager.default.fileExists(atPath: env.stateFile.path))
        }
    }

    @Test("Events are returned ascending by timestamp")
    func eventsSortedByTimestamp() throws {
        try withTempEnvironment { env in
            let late = try assistantRow(
                requestId: "req_1", messageId: "msg_1", timestamp: "2026-07-12T09:00:00.000Z")
            let early = try assistantRow(
                requestId: "req_2", messageId: "msg_2", timestamp: "2026-07-11T23:10:08.208Z")
            try env.writeTranscript([late, early], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            try scanner.scan()

            #expect(scanner.events.map(\.key) == ["req_2|msg_2", "req_1|msg_1"])
            #expect(scanner.events[0].timestamp < scanner.events[1].timestamp)
        }
    }

    // MARK: Incremental behaviour

    @Test("A second pass reads only appended lines, and a no-op pass reads nothing")
    func incrementalScanReadsOnlyAppendedBytes() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(requestId: "req_1", messageId: "msg_1")], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let first = try scanner.scan()
            try scanner.persistState()
            #expect(first.totalEventCount == 1)
            #expect(first.filesScanned == 1)

            let appended = try assistantRow(requestId: "req_2", messageId: "msg_2") + "\n"
            try env.append(appended, path: "projA/a.jsonl")

            let second = try scanner.scan()
            #expect(second.newEventCount == 1)
            #expect(second.totalEventCount == 2)
            #expect(second.filesScanned == 1)
            #expect(second.bytesRead == appended.utf8.count)
            #expect(second.rawRowsSeen == 2)

            let third = try scanner.scan()
            #expect(third.newEventCount == 0)
            #expect(third.filesScanned == 0)
            #expect(third.bytesRead == 0)
            #expect(third.totalEventCount == 2)
            #expect(third.rawRowsSeen == 2)
        }
    }

    @Test("A trailing line with no newline is left for the next pass")
    func partialTrailingLineDeferred() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(requestId: "req_1", messageId: "msg_1")], path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            try scanner.scan()

            let full = try assistantRow(requestId: "req_2", messageId: "msg_2")
            let half = String(full.prefix(full.count / 2))
            try env.append(half, path: "projA/a.jsonl")
            let midWrite = try scanner.scan()
            #expect(midWrite.newEventCount == 0)
            #expect(midWrite.bytesRead == 0)

            try env.append(String(full.dropFirst(half.count)) + "\n", path: "projA/a.jsonl")
            let completed = try scanner.scan()
            #expect(completed.newEventCount == 1)
            #expect(completed.totalEventCount == 2)
        }
    }

    @Test("A file smaller than its stored offset is rescanned from 0")
    func truncatedFileRescannedFromZero() throws {
        try withTempEnvironment { env in
            let rows = try (1...3).map {
                try assistantRow(requestId: "req_\($0)", messageId: "msg_\($0)")
            }
            try env.writeTranscript(rows, path: "projA/a.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let first = try scanner.scan()
            #expect(first.totalEventCount == 3)
            #expect(first.rawRowsSeen == 3)

            // Rotated in place: fewer bytes than the offset we stopped at.
            try env.writeTranscript(
                [try assistantRow(requestId: "req_9", messageId: "msg_9", output: 77)],
                path: "projA/a.jsonl")

            let second = try scanner.scan()
            #expect(second.newEventCount == 1)
            #expect(second.filesScanned == 1)
            // Events already deduplicated stay in the map: the cache records what has been
            // counted, it is not a mirror of the bytes currently on disk.
            #expect(second.totalEventCount == 4)
            // `rawRowsSeen` is cumulative — rows *ever* read — so it keeps the 3 rows the
            // rotated-away content contributed and adds the 1 new one. Restarting the count
            // with the file would drive it below `totalEventCount` (which still holds those
            // 3 events) and make `inflationFactor` report a nonsensical ratio under 1.
            #expect(second.rawRowsSeen == 4)
            #expect(second.inflationFactor == 1)
            #expect(scanner.events.contains { $0.key == "req_9|msg_9" })
        }
    }

    // MARK: Cache persistence

    @Test("Persisted cache survives a fresh scanner instance")
    func cacheSurvivesFreshInstance() throws {
        try withTempEnvironment { env in
            let rows = [
                try assistantRow(
                    requestId: "req_1", messageId: "msg_1", input: 11, output: 22,
                    cacheRead: 33, cacheCreate: 44, create5m: 40, create1h: 4, effort: "high"),
                try assistantRow(requestId: nil, messageId: "msg_2", output: 5),
            ]
            try env.writeTranscript(rows, path: "projA/a.jsonl")

            let first = env.scanner()
            try first.loadPersistedState()
            try first.scan()
            try first.persistState()
            let expected = first.events

            let second = env.scanner()
            try second.loadPersistedState()
            #expect(second.events == expected)
            #expect(second.rawRowsSeen == 2)

            // Offsets came back too, so nothing is re-read and nothing is counted twice.
            let result = try second.scan()
            #expect(result.bytesRead == 0)
            #expect(result.newEventCount == 0)
            #expect(result.totalEventCount == 2)
            #expect(second.events == expected)

            let carried = try #require(second.events.first { $0.key == "req_1|msg_1" })
            #expect(carried.tokens == TokenCounts(
                input: 11, output: 22, cacheCreate: 44, cacheRead: 33,
                cacheCreate5m: 40, cacheCreate1h: 4))
            #expect(carried.effort == "high")
        }
    }

    @Test("A duplicate appended after the cache was persisted merges instead of double-counting")
    func duplicateArrivingInALaterPassCannotDoubleCount() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(
                    requestId: "req_1", messageId: "msg_1", input: 10, output: 500)],
                path: "projA/a.jsonl")

            let first = env.scanner()
            try first.loadPersistedState()
            try first.scan()
            try first.persistState()

            // The same request is written again in bytes the scanner has not read yet: the
            // final form, then a smaller partial re-emission. Byte offsets alone cannot save
            // us here — the file genuinely grew, so these bytes *must* be read — which is why
            // the event map itself is persisted and not merely the offsets.
            let larger = try assistantRow(
                requestId: "req_1", messageId: "msg_1", input: 10, output: 900, cacheRead: 7)
            let smaller = try assistantRow(
                requestId: "req_1", messageId: "msg_1", input: 10, output: 100)
            try env.append(larger + "\n" + smaller + "\n", path: "projA/a.jsonl")

            let second = env.scanner()
            try second.loadPersistedState()
            // The map came back from the cache, not just the offsets.
            #expect(second.events.count == 1)

            let result = try second.scan()
            #expect(result.newEventCount == 0)
            #expect(result.totalEventCount == 1)
            #expect(result.rawRowsSeen == 3)
            #expect(result.bytesRead == (larger + "\n" + smaller + "\n").utf8.count)

            let event = try #require(second.events.first)
            // Three policies are told apart here: summing gives 1500, first-wins 500 (the
            // already-cached value), last-wins 100 (the trailing partial). Only element-wise
            // max gives 900, and only max keeps `cacheRead` at 7 rather than dropping it.
            #expect(event.tokens.output == 900)
            #expect(event.tokens.cacheRead == 7)
            #expect(event.tokens.input == 10)

            // The merged value, not the pre-merge one, is what a third pass inherits.
            try second.persistState()
            let third = env.scanner()
            try third.loadPersistedState()
            #expect(third.events.first?.tokens.output == 900)
            let rescan = try third.scan()
            #expect(rescan.totalEventCount == 1)
            #expect(rescan.newEventCount == 0)
        }
    }

    @Test("A missing event cache forces a full re-read rather than trusting offsets")
    func offsetsAreIgnoredWithoutACache() throws {
        try withTempEnvironment { env in
            try env.writeTranscript(
                [try assistantRow(requestId: "req_1", messageId: "msg_1")], path: "projA/a.jsonl")

            let first = env.scanner()
            try first.loadPersistedState()
            try first.scan()
            try first.persistState()

            try FileManager.default.removeItem(at: env.cacheFile)

            let second = env.scanner()
            try second.loadPersistedState()
            #expect(second.events.isEmpty)
            let result = try second.scan()
            #expect(result.totalEventCount == 1)
            #expect(result.bytesRead > 0)
        }
    }

    @Test("A missing transcript root scans cleanly")
    func emptyRootIsHarmless() throws {
        try withTempEnvironment { env in
            let scanner = TranscriptScanner(
                root: env.root.appending(path: "does-not-exist"),
                stateFile: env.stateFile, cacheFile: env.cacheFile)
            try scanner.loadPersistedState()
            let result = try scanner.scan()
            #expect(result == ScanResult(
                newEventCount: 0, totalEventCount: 0, filesScanned: 0, bytesRead: 0,
                rawRowsSeen: 0))
            #expect(result.inflationFactor == 1)
            #expect(scanner.events.isEmpty)
        }
    }

    @Test("A file larger than the read chunk streams correctly")
    func streamsAcrossChunkBoundaries() throws {
        try withTempEnvironment { env in
            var lines: [String] = []
            for index in 0..<2500 {
                let row = try assistantRow(
                    requestId: "req_\(index)", messageId: "msg_\(index)", output: 100)
                lines.append(row)
                lines.append(row)   // every row duplicated: a 2× inflation factor
            }
            try env.writeTranscript(lines, path: "big/big.jsonl")

            let scanner = env.scanner()
            try scanner.loadPersistedState()
            let result = try scanner.scan()

            #expect(result.rawRowsSeen == 5000)
            #expect(result.totalEventCount == 2500)
            #expect(result.inflationFactor == 2)
            let size = try Data(contentsOf: env.root.appending(path: "big/big.jsonl")).count
            #expect(result.bytesRead == size)
        }
    }
}

// MARK: - Harness

/// Temp locations resolved through `Paths` while the overrides are installed.
private struct TempEnvironment {
    let root: URL
    let stateFile: URL
    let cacheFile: URL

    func scanner() -> TranscriptScanner {
        TranscriptScanner(root: root, stateFile: stateFile, cacheFile: cacheFile)
    }

    func writeTranscript(_ lines: [String], path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url, options: .atomic)
    }

    func append(_ text: String, path: String) throws {
        let handle = try FileHandle(forWritingTo: root.appending(path: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

/// Raised instead of letting a test fall through to the real `~/.claude`.
private struct OverridesNotInstalled: Error {}

/// Redirects both `Paths` overrides at a throwaway directory and always restores them.
private func withTempEnvironment(_ body: (TempEnvironment) throws -> Void) throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "TranscriptScannerTests-\(UUID().uuidString)")
    let projects = base.appending(path: "projects")
    let support = base.appending(path: "support")
    let manager = FileManager.default
    try manager.createDirectory(at: projects, withIntermediateDirectories: true)
    try manager.createDirectory(at: support, withIntermediateDirectories: true)
    Paths.claudeProjectsOverride = projects
    Paths.supportDirectoryOverride = support
    defer {
        Paths.claudeProjectsOverride = nil
        Paths.supportDirectoryOverride = nil
        try? manager.removeItem(at: base)
    }
    let env = TempEnvironment(
        root: Paths.claudeProjects, stateFile: Paths.scanStateFile, cacheFile: Paths.eventCacheFile)
    // The overrides are process-global: if a suite running in parallel has cleared them, fail
    // loudly rather than reading the real transcript corpus.
    guard env.root == projects, env.cacheFile.path.hasPrefix(support.path) else {
        throw OverridesNotInstalled()
    }
    try body(env)
}

/// One real-shaped assistant row on a single line. `effort` sits at the top level and
/// `agentId` only accompanies a sidechain, exactly as the transcripts do it.
private func assistantRow(
    requestId: String?,
    messageId: String,
    model: String = "claude-sonnet-5",
    timestamp: String = "2026-07-11T23:10:08.208Z",
    input: Int = 10,
    output: Int = 100,
    cacheRead: Int = 0,
    cacheCreate: Int = 0,
    create5m: Int = 0,
    create1h: Int = 0,
    sessionId: String = "sess-1",
    cwd: String = "/Users/x/claudeusage",
    effort: String? = nil,
    isSidechain: Bool = false,
    agentId: String? = nil,
    omitRequestId: Bool = false
) throws -> String {
    var row: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "sessionId": sessionId,
        "cwd": cwd,
        "uuid": UUID().uuidString,
        "version": "2.0.0",
        "userType": "external",
        "isSidechain": isSidechain,
        "message": [
            "id": messageId,
            "role": "assistant",
            "model": model,
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_creation_input_tokens": cacheCreate,
                "cache_read_input_tokens": cacheRead,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": create5m,
                    "ephemeral_1h_input_tokens": create1h,
                ],
            ],
        ],
    ]
    if !omitRequestId { row["requestId"] = requestId ?? NSNull() }
    if let effort { row["effort"] = effort }
    if let agentId { row["agentId"] = agentId }
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
