import Foundation

// MARK: - SampleStore

/// Persistence for the two things the app must survive a relaunch with: the poll
/// series that burn rate is fitted from, and the last good usage snapshot.
///
/// The series is JSONL rather than one JSON array so a poll costs a single append
/// and a crash mid-write can only damage the final line. Anything that fails to
/// decode is dropped on load: a truncated tail must never stop the app from
/// starting, and one bad byte must never cost the whole history.
public final class SampleStore {
    private let samplesFile: URL
    private let snapshotFile: URL
    private let fileManager = FileManager.default
    private var storage: [Sample] = []

    public init(
        samplesFile: URL = Paths.samplesFile,
        snapshotFile: URL = Paths.cachedSnapshotFile
    ) {
        self.samplesFile = samplesFile
        self.snapshotFile = snapshotFile
    }

    /// The loaded series, ascending by `t`. Empty until `load()` runs.
    public var samples: [Sample] { storage }

    /// Where the series is persisted. Exposed so callers can report the path.
    public var samplesURL: URL { samplesFile }

    /// Where the cached snapshot is persisted.
    public var snapshotURL: URL { snapshotFile }

    // MARK: Series

    /// Reads the whole series into memory. A missing file is a normal cold start,
    /// not an error. Undecodable lines are skipped.
    public func load() throws {
        storage = try readSeries().samples
    }

    /// Appends one JSON line and keeps the in-memory series ordered. The write is
    /// an append rather than a rewrite so an interrupted poll cannot corrupt
    /// samples that were already durable.
    public func append(_ sample: Sample) throws {
        try prepareDirectory(for: samplesFile)
        var line = try JSONEncoder.claudeMeter().encode(sample)
        line.append(Self.newline)

        if fileManager.fileExists(atPath: samplesFile.path) {
            // `forUpdating` (O_RDWR), not `forWritingTo` (O_WRONLY): the
            // trailing-byte probe below is a read, and reading a write-only
            // descriptor fails with EBADF.
            let handle = try FileHandle(forUpdating: samplesFile)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // A previous write cut off mid-line leaves the file without a trailing
            // newline; separate rather than splice, so only that line is lost.
            if end > 0, try Self.lastByte(of: handle, fileLength: end) != Self.newline {
                try handle.write(contentsOf: Data([Self.newline]))
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: samplesFile, options: .atomic)
        }

        var index = storage.count
        while index > 0, storage[index - 1].t > sample.t { index -= 1 }
        storage.insert(sample, at: index)
    }

    /// Samples at or after `since`, ascending. Boundary is inclusive.
    public func samples(since: Date) -> [Sample] {
        storage.filter { $0.t >= since }
    }

    /// Drops samples older than `cutoff` and rewrites the file from what remains.
    /// Returns how many were removed, and leaves `samples` equal to what survived.
    ///
    /// The file, not `storage`, is the source of truth here: `append` writes
    /// through, so the file is always a superset of the in-memory series, and a
    /// caller that prunes before (or without) `load()` would otherwise rewrite the
    /// file from a partial series and silently discard earlier runs' history.
    ///
    /// Prune is also the only point that clears damage, so it rewrites whenever the
    /// file held an undecodable line even if nothing was old enough to drop.
    /// Keying the rewrite on the removed count alone would let interrupted writes
    /// accumulate forever: once every real sample is newer than the cutoff, each
    /// later prune would again find nothing to remove and again skip the rewrite.
    /// The returned count stays a count of *samples* — garbage lines were never
    /// samples, so healing them reports 0.
    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> Int {
        let series: SeriesRead
        if fileManager.fileExists(atPath: samplesFile.path) {
            series = try readSeries()
        } else {
            // Nothing on disk to lose, so the in-memory series is the only record
            // of what was appended.
            series = SeriesRead(samples: storage, hadUndecodableLines: false)
        }

        let kept = series.samples.filter { $0.t >= cutoff }
        let removed = series.samples.count - kept.count
        guard removed > 0 || series.hadUndecodableLines else {
            storage = kept
            return 0
        }

        try prepareDirectory(for: samplesFile)
        let encoder = JSONEncoder.claudeMeter()
        var data = Data()
        for sample in kept {
            let line = try encoder.encode(sample)
            data.append(line)
            data.append(Self.newline)
        }
        try data.write(to: samplesFile, options: .atomic)
        storage = kept
        return removed
    }

    // MARK: Snapshot cache

    /// Stores the last successful poll so a cold start has something to render
    /// before the network answers.
    public func cacheSnapshot(_ snapshot: UsageSnapshot) throws {
        try prepareDirectory(for: snapshotFile)
        let data = try JSONEncoder.claudeMeter().encode(snapshot)
        try data.write(to: snapshotFile, options: .atomic)
    }

    /// Never throws: the UI calls this on the launch path, where a missing,
    /// truncated or stale-format cache file is an expected state and not worth an
    /// error.
    public func loadCachedSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        return try? JSONDecoder.claudeMeter().decode(UsageSnapshot.self, from: data)
    }

    // MARK: - Private

    private static let newline = UInt8(ascii: "\n")

    /// What one read of the file yielded. The damage flag is carried separately
    /// because `prune` has to distinguish "nothing to drop" from "nothing to do".
    private struct SeriesRead {
        var samples: [Sample]
        var hadUndecodableLines: Bool
    }

    /// The persisted series, ascending. A missing file is an empty series.
    private func readSeries() throws -> SeriesRead {
        guard fileManager.fileExists(atPath: samplesFile.path) else {
            return SeriesRead(samples: [], hadUndecodableLines: false)
        }
        let data = try Data(contentsOf: samplesFile)
        var read = Self.decodeSamples(from: data)
        read.samples = Self.ascending(read.samples)
        return read
    }

    private func prepareDirectory(for file: URL) throws {
        let directory = file.deletingLastPathComponent()
        // Compare paths rather than URLs: `deletingLastPathComponent()` returns a
        // trailing slash that `Paths.supportDirectory` does not carry, so `==` on
        // the URLs would never match and the `Paths` branch would be dead code.
        if directory.standardizedFileURL.path == Paths.supportDirectory.standardizedFileURL.path {
            try Paths.ensureSupportDirectory()
        } else {
            // An injected file (tests, or a future export location) can live
            // outside the support directory; create its parent directly.
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Splits on newlines over raw bytes rather than decoding the file as a
    /// String: a corrupt line can hold invalid UTF-8, which would otherwise take
    /// the whole file down with it.
    private static func decodeSamples(from data: Data) -> SeriesRead {
        let decoder = JSONDecoder.claudeMeter()
        var result = SeriesRead(samples: [], hadUndecodableLines: false)
        for chunk in data.split(separator: newline, omittingEmptySubsequences: true) {
            var line = Data(chunk)
            while let last = line.last,
                  last == UInt8(ascii: "\r") || last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") {
                line.removeLast()
            }
            guard !line.isEmpty else { continue }
            if let sample = try? decoder.decode(Sample.self, from: line) {
                result.samples.append(sample)
            } else {
                result.hadUndecodableLines = true
            }
        }
        return result
    }

    /// Stable ascending sort: samples sharing a timestamp keep their file order.
    private static func ascending(_ samples: [Sample]) -> [Sample] {
        samples.enumerated()
            .sorted { a, b in
                a.element.t == b.element.t ? a.offset < b.offset : a.element.t < b.element.t
            }
            .map(\.element)
    }

    private static func lastByte(of handle: FileHandle, fileLength: UInt64) throws -> UInt8? {
        guard fileLength > 0 else { return nil }
        try handle.seek(toOffset: fileLength - 1)
        defer { try? handle.seek(toOffset: fileLength) }
        return try handle.read(upToCount: 1)?.last
    }
}
