import Foundation

// MARK: - Scan result

/// Outcome of one incremental pass over the transcript tree.
public struct ScanResult: Sendable, Equatable {
    /// Keys that were not already in the dedup map. Repeats of a known key merge instead.
    public let newEventCount: Int
    public let totalEventCount: Int
    /// Files that actually yielded new bytes this pass. Files already at their stored
    /// offset are skipped entirely, so a no-op rescan reports 0.
    public let filesScanned: Int
    public let bytesRead: Int
    /// Cumulative count of assistant rows seen before dedup — lets the UI show the inflation factor.
    public let rawRowsSeen: Int

    public init(
        newEventCount: Int, totalEventCount: Int, filesScanned: Int, bytesRead: Int,
        rawRowsSeen: Int
    ) {
        self.newEventCount = newEventCount
        self.totalEventCount = totalEventCount
        self.filesScanned = filesScanned
        self.bytesRead = bytesRead
        self.rawRowsSeen = rawRowsSeen
    }

    /// Rows read per distinct request — how many times the average request was written to a
    /// transcript. Duplicate rows are common, so this typically reads well above 1.0; the *token*
    /// over-count a naive sum would produce is a separate, slightly lower figure, because the
    /// repeats are not uniformly sized.
    /// Normally ≥ 1, since every event came from a counted row. It can read lower only when a
    /// persisted event cache is adopted without its companion offsets and the transcripts that
    /// produced those events are themselves gone.
    public var inflationFactor: Double {
        totalEventCount > 0 ? Double(rawRowsSeen) / Double(totalEventCount) : 1
    }
}

// MARK: - Scanner

/// Incremental reader for `~/.claude/projects/**/*.jsonl`.
///
/// Three properties of the transcript corpus drive the design:
///
/// 1. It can grow to hundreds of megabytes, so files are streamed line by line and re-read
///    only from a persisted byte offset.
/// 2. Assistant rows duplicate heavily — naive summing over-counts tokens substantially — so
///    rows are keyed on `(requestId, message.id)` and repeats are merged rather than summed.
/// 3. Duplicates of a row already counted in an earlier pass show up in *later* bytes, so
///    byte offsets alone are not enough state: the deduplicated event map is persisted too.
public final class TranscriptScanner {
    /// Rows from this pseudo-model carry token counts that were never billed.
    public static let syntheticModel = "<synthetic>"

    private static let stateVersion = 1
    private static let cacheVersion = 1
    private static let chunkSize = 1 << 18

    private let root: URL
    private let stateFile: URL
    private let cacheFile: URL

    private var fileStates: [String: FileState] = [:]
    private var eventsByKey: [String: UsageEvent] = [:]
    private var sortedEvents: [UsageEvent]?

    public init(
        root: URL = Paths.claudeProjects,
        stateFile: URL = Paths.scanStateFile,
        cacheFile: URL = Paths.eventCacheFile
    ) {
        self.root = root
        self.stateFile = stateFile
        self.cacheFile = cacheFile
    }

    // MARK: Public state

    /// Deduplicated events, ascending by timestamp. Valid after `loadPersistedState()`/`scan()`.
    public var events: [UsageEvent] {
        if let sortedEvents { return sortedEvents }
        let sorted = eventsByKey.values.sorted {
            $0.timestamp == $1.timestamp ? $0.key < $1.key : $0.timestamp < $1.timestamp
        }
        sortedEvents = sorted
        return sorted
    }

    public var rawRowsSeen: Int {
        fileStates.values.reduce(0) { $0 + $1.rawRows }
    }

    // MARK: Persistence

    public func loadPersistedState() throws {
        fileStates = [:]
        eventsByKey = [:]
        sortedEvents = nil

        guard let cacheData = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder.claudeMeter().decode(EventCache.self, from: cacheData),
              cache.version == Self.cacheVersion
        else {
            // No trustworthy event cache, so the stored offsets must not be adopted either:
            // they would skip rows whose events we no longer hold.
            return
        }
        for event in cache.events { eventsByKey[event.key] = event }

        guard let stateData = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(ScanState.self, from: stateData),
              state.version == Self.stateVersion
        else {
            // Events without offsets: a full re-read is safe because merging is idempotent.
            return
        }
        fileStates = state.files
    }

    /// The event cache is written *before* the offsets, and the order is load-bearing. Only one
    /// of the two writes can be the last to land if the process dies in between, and the two
    /// resulting states are not equally recoverable: offsets ahead of the cache silently skip
    /// bytes whose events were never saved (permanent under-count), while a cache ahead of the
    /// offsets merely re-reads bytes it already holds, which `maxed(with:)` makes idempotent.
    public func persistState() throws {
        let cache = EventCache(version: Self.cacheVersion, events: events)
        try write(try JSONEncoder.claudeMeter().encode(cache), to: cacheFile)
        let state = ScanState(version: Self.stateVersion, files: fileStates)
        try write(try JSONEncoder().encode(state), to: stateFile)
    }

    // MARK: Scanning

    @discardableResult
    public func scan() throws -> ScanResult {
        var newEventCount = 0
        var filesScanned = 0
        var bytesRead = 0

        for url in transcriptFiles() {
            guard let size = fileSize(of: url) else { continue }
            let key = stateKey(for: url)
            var state = fileStates[key] ?? FileState(offset: 0, rawRows: 0)

            // A file smaller than where we stopped was truncated or rotated in place;
            // its byte offset means nothing any more, so start over from 0. `rawRows` is
            // deliberately *not* reset: it counts rows ever read, and the events those rows
            // produced are still in the map, so zeroing it would drive `rawRowsSeen` below
            // `totalEventCount` and make `inflationFactor` report a ratio under 1.
            if size < state.offset { state.offset = 0 }

            guard size > state.offset else {
                fileStates[key] = state
                continue
            }

            let start = state.offset
            var rawRows = 0
            let consumed: UInt64
            do {
                consumed = try forEachLine(in: url, from: start) { line in
                    guard let event = Self.makeEvent(from: line) else { return }
                    rawRows += 1
                    if self.ingest(event) { newEventCount += 1 }
                }
            } catch {
                // An unreadable or vanished file must not abort the pass; its offset is
                // left untouched so the next pass retries.
                continue
            }

            if consumed > start { filesScanned += 1 }
            bytesRead += Int(consumed - start)
            state.offset = consumed
            state.rawRows += rawRows
            fileStates[key] = state
        }

        return ScanResult(
            newEventCount: newEventCount,
            totalEventCount: eventsByKey.count,
            filesScanned: filesScanned,
            bytesRead: bytesRead,
            rawRowsSeen: rawRowsSeen
        )
    }

    public static func dedupKey(requestId: String?, messageId: String) -> String {
        "\(requestId ?? "")|\(messageId)"
    }

    // MARK: - Row ingestion

    /// Returns true when the key had not been seen before.
    private func ingest(_ event: UsageEvent) -> Bool {
        sortedEvents = nil
        guard let existing = eventsByKey[event.key] else {
            eventsByKey[event.key] = event
            return true
        }
        eventsByKey[event.key] = Self.merge(existing, event)
        return false
    }

    /// Element-wise max, never a sum and never first-wins: a minority of repeated keys carry
    /// differing payloads (a streamed row followed by its final form), so the largest value of
    /// each field is the true one.
    private static func merge(_ a: UsageEvent, _ b: UsageEvent) -> UsageEvent {
        UsageEvent(
            key: a.key,
            timestamp: min(a.timestamp, b.timestamp),
            sessionId: a.sessionId.isEmpty ? b.sessionId : a.sessionId,
            cwd: a.cwd.isEmpty ? b.cwd : a.cwd,
            model: a.model,
            effort: a.effort ?? b.effort,
            isSidechain: a.isSidechain || b.isSidechain,
            agentId: a.agentId ?? b.agentId,
            tokens: a.tokens.maxed(with: b.tokens)
        )
    }

    /// `nil` for anything that is not a billable assistant row: other `type`s, rows with no
    /// `message.usage`, `<synthetic>` rows, and malformed JSON.
    private static func makeEvent(from line: Data) -> UsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let row = object as? [String: Any],
              row["type"] as? String == "assistant",
              let message = row["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let messageId = message["id"] as? String,
              let model = message["model"] as? String,
              !model.isEmpty, model != syntheticModel,
              let stamp = row["timestamp"] as? String,
              let timestamp = ISO8601.date(from: stamp)
        else { return nil }

        let creation = usage["cache_creation"] as? [String: Any]
        let tokens = TokenCounts(
            input: intValue(usage["input_tokens"]),
            output: intValue(usage["output_tokens"]),
            cacheCreate: intValue(usage["cache_creation_input_tokens"]),
            cacheRead: intValue(usage["cache_read_input_tokens"]),
            cacheCreate5m: intValue(creation?["ephemeral_5m_input_tokens"]),
            cacheCreate1h: intValue(creation?["ephemeral_1h_input_tokens"])
        )

        return UsageEvent(
            key: dedupKey(requestId: row["requestId"] as? String, messageId: messageId),
            timestamp: timestamp,
            sessionId: row["sessionId"] as? String ?? "",
            cwd: row["cwd"] as? String ?? "",
            model: model,
            effort: row["effort"] as? String,   // top level, not under `message`
            isSidechain: row["isSidechain"] as? Bool ?? false,
            agentId: row["agentId"] as? String,
            tokens: tokens
        )
    }

    private static func intValue(_ any: Any?) -> Int {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String, let parsed = Int(string) { return parsed }
        return 0
    }

    // MARK: - Filesystem

    private func transcriptFiles() -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == false { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Streams the complete newline-terminated lines starting at `startOffset` and returns the
    /// offset just past the last one. A trailing fragment with no newline is deliberately left
    /// unconsumed: the CLI may still be writing it, and the next pass will see it whole.
    private func forEachLine(
        in url: URL, from startOffset: UInt64, _ body: (Data) -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)

        var consumed = startOffset
        var pending = Data()

        // The two pools are what make this actually streaming. `read(upToCount:)` hands back an
        // autoreleased buffer and `JSONSerialization` builds an autoreleased object graph per
        // line; a synchronous scan drains no pool of its own, so without these every chunk and
        // every parsed row stays resident until the whole pass returns — peak memory then scales
        // with the size of the corpus instead of staying flat. Draining per chunk caps residency
        // at one chunk, and draining per line caps the parsed graph at one row.
        while true {
            let exhausted: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    return true
                }
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    let line = Data(pending[lineStart..<newline])
                    consumed += UInt64(newline - lineStart + 1)
                    lineStart = newline + 1
                    let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
                    if !trimmed.isEmpty { autoreleasepool { body(Data(trimmed)) } }
                }
                pending = Data(pending[lineStart...])
                return false
            }
            if exhausted { break }
        }
        return consumed
    }

    private func fileSize(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    /// State is keyed by path relative to `root` so a moved or overridden root does not
    /// silently match stale offsets from an absolute path.
    private func stateKey(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Persisted shapes

    private struct FileState: Codable {
        var offset: UInt64
        var rawRows: Int
    }

    private struct ScanState: Codable {
        var version: Int
        var files: [String: FileState]
    }

    private struct EventCache: Codable {
        var version: Int
        var events: [UsageEvent]
    }
}
