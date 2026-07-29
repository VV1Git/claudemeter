import Foundation
import Testing

@testable import UsageCore

@Suite(.serialized)
struct SampleStoreTests {

    // MARK: Harness

    /// Every case gets its own temp directory and the store is pointed at explicit
    /// files, so nothing here touches the real `~/Library/Application Support`.
    ///
    /// The `Paths.*Override` globals are deliberately *not* used except in
    /// `defaultLocationsCreateSupportDirectory`: swift-testing runs suites in
    /// parallel, `.serialized` only orders cases inside this suite, and every suite
    /// in this target redirects the same two globals. A case that held the override
    /// across a filesystem round trip could therefore read another suite's
    /// directory — or have its own deleted underneath it.
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SampleStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func makeStore(in directory: URL) -> SampleStore {
        SampleStore(
            samplesFile: directory.appending(path: "samples.jsonl"),
            snapshotFile: directory.appending(path: "last-snapshot.json")
        )
    }

    private func samplesURL(in directory: URL) -> URL {
        directory.appending(path: "samples.jsonl")
    }

    private func sample(_ t: Date, five: Double?, seven: Double?, reset: Date? = nil) -> Sample {
        Sample(
            t: t,
            fiveHourPct: five,
            fiveHourResetsAt: reset,
            sevenDayPct: seven,
            sevenDayResetsAt: reset
        )
    }

    /// Whole seconds so `Date` equality survives the epoch-seconds JSON round trip.
    private var base: Date { Date(timeIntervalSince1970: 1_785_000_000) }

    // MARK: Series round trip

    @Test("append then load preserves every field and the ascending order")
    func appendLoadRoundTrip() throws {
        try withTemporaryDirectory { root in
            let reset = base.addingTimeInterval(3 * 3600)
            let written = [
                sample(base, five: 17, seven: 7, reset: reset),
                sample(base.addingTimeInterval(300), five: 21.5, seven: 7.25, reset: reset),
                sample(base.addingTimeInterval(600), five: nil, seven: 8, reset: nil),
            ]

            let writer = makeStore(in: root)
            for s in written { try writer.append(s) }
            #expect(writer.samples == written)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == written)
            #expect(reader.samples[1].fiveHourPct == 21.5)
            #expect(reader.samples[1].fiveHourResetsAt == reset)
            #expect(reader.samples[2].fiveHourPct == nil)
            #expect(reader.samples[2].fiveHourResetsAt == nil)
        }
    }

    @Test("one file, one line per sample")
    func appendWritesOneLinePerSample() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            try store.append(sample(base, five: 1, seven: 1))
            try store.append(sample(base.addingTimeInterval(60), five: 2, seven: 1))
            try store.append(sample(base.addingTimeInterval(120), five: 3, seven: 1))

            let text = try String(contentsOf: samplesURL(in: root), encoding: .utf8)
            let lines = text.split(separator: "\n").filter { !$0.isEmpty }
            #expect(lines.count == 3)
        }
    }

    @Test("out-of-order appends still read back ascending by t")
    func outOfOrderAppendsSort() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            try store.append(sample(base.addingTimeInterval(600), five: 30, seven: 9))
            try store.append(sample(base, five: 10, seven: 7))
            try store.append(sample(base.addingTimeInterval(300), five: 20, seven: 8))
            #expect(store.samples.map(\.fiveHourPct) == [10, 20, 30])

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples.map(\.t) == [base, base.addingTimeInterval(300), base.addingTimeInterval(600)])
        }
    }

    /// A rewrite-all implementation would drop the undecodable line and re-encode
    /// the survivors, so byte-for-byte preservation of the existing prefix is the
    /// assertion that pins `append` to a real append.
    @Test("append extends the file instead of rewriting it")
    func appendPreservesExistingBytes() throws {
        try withTemporaryDirectory { root in
            let first = sample(base, five: 12, seven: 5)
            var original = Data()
            original.append(try JSONEncoder.claudeMeter().encode(first))
            original.append(0x0A)
            original.append(Data("{\"corrupt-marker\":".utf8))
            original.append(0x0A)
            try original.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples == [first])

            let fresh = sample(base.addingTimeInterval(60), five: 13, seven: 5)
            try store.append(fresh)

            let after = try Data(contentsOf: samplesURL(in: root))
            #expect(after.count > original.count)
            #expect(after.prefix(original.count) == original)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [first, fresh])
        }
    }

    // MARK: Corruption tolerance

    @Test("a corrupt middle line is skipped and the surrounding samples survive")
    func corruptMiddleLineSkipped() throws {
        try withTemporaryDirectory { root in
            let encoder = JSONEncoder.claudeMeter()
            let first = sample(base, five: 12, seven: 5)
            let last = sample(base.addingTimeInterval(600), five: 34, seven: 6)

            var data = Data()
            data.append(try encoder.encode(first))
            data.append(0x0A)
            data.append(Data("{\"t\":not-json,".utf8))
            data.append(0x0A)
            data.append(try encoder.encode(last))
            data.append(0x0A)
            try data.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples == [first, last])
        }
    }

    /// Bytes that are not valid UTF-8 must not take the whole file down: the loader
    /// splits on raw newlines rather than decoding the file as a String.
    @Test("a line of invalid UTF-8 is skipped and the rest of the series survives")
    func invalidUTF8LineSkipped() throws {
        try withTemporaryDirectory { root in
            let encoder = JSONEncoder.claudeMeter()
            let first = sample(base, five: 1, seven: 1)
            let last = sample(base.addingTimeInterval(300), five: 2, seven: 1)

            var data = Data()
            data.append(try encoder.encode(first))
            data.append(0x0A)
            data.append(Data([0xFF, 0xFE, 0x7B, 0xC0, 0x80]))
            data.append(0x0A)
            data.append(try encoder.encode(last))
            data.append(0x0A)
            try data.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples == [first, last])
        }
    }

    @Test("load on a missing samples file yields an empty series without throwing")
    func loadMissingFile() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples.isEmpty)
        }
    }

    @Test("load on an empty samples file yields an empty series without throwing")
    func loadEmptyFile() throws {
        try withTemporaryDirectory { root in
            try Data().write(to: samplesURL(in: root))
            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples.isEmpty)

            let next = sample(base, five: 1, seven: 1)
            try store.append(next)
            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [next])
        }
    }

    @Test("appending after a truncated tail keeps the new sample readable")
    func appendAfterTruncatedTail() throws {
        try withTemporaryDirectory { root in
            let good = sample(base, five: 5, seven: 5)
            var data = try JSONEncoder.claudeMeter().encode(good)
            data.append(0x0A)
            data.append(Data("{\"t\":1785".utf8))   // no trailing newline: interrupted write
            try data.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            try store.load()
            #expect(store.samples == [good])

            let fresh = sample(base.addingTimeInterval(60), five: 6, seven: 5)
            try store.append(fresh)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [good, fresh])
        }
    }

    // MARK: since / prune

    @Test("samples(since:) is inclusive at the boundary")
    func samplesSinceIsInclusive() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let times = [0, 300, 600, 900].map { base.addingTimeInterval(TimeInterval($0)) }
            for (i, t) in times.enumerated() {
                try store.append(sample(t, five: Double(i), seven: 1))
            }
            #expect(store.samples(since: times[1]).map(\.t) == Array(times[1...]))
            #expect(store.samples(since: times[3].addingTimeInterval(1)).isEmpty)
            #expect(store.samples(since: times[0].addingTimeInterval(-1)).count == 4)
        }
    }

    @Test("prune drops only older entries and rewrites the file")
    func pruneRewritesFile() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let old1 = sample(base, five: 10, seven: 4)
            let old2 = sample(base.addingTimeInterval(3600), five: 20, seven: 5)
            let keep = sample(base.addingTimeInterval(7200), five: 30, seven: 6)
            for s in [old1, old2, keep] { try store.append(s) }

            let removed = try store.prune(olderThan: base.addingTimeInterval(5400))
            #expect(removed == 2)
            #expect(store.samples == [keep])

            let text = try String(contentsOf: samplesURL(in: root), encoding: .utf8)
            #expect(text.split(separator: "\n").filter { !$0.isEmpty }.count == 1)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [keep])
        }
    }

    @Test("prune with nothing to remove reports zero and leaves the series intact")
    func pruneNoOp() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let a = sample(base, five: 10, seven: 4)
            let b = sample(base.addingTimeInterval(600), five: 11, seven: 4)
            try store.append(a)
            try store.append(b)

            let removed = try store.prune(olderThan: base.addingTimeInterval(-1))
            #expect(removed == 0)
            #expect(store.samples == [a, b])

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [a, b])
        }
    }

    /// Regression: prune must rewrite from the file, not from whatever happens to
    /// be in memory. A store that never called `load()` holds only the samples it
    /// appended itself, so a memory-based rewrite would delete every earlier run's
    /// history and report a count of 0.
    @Test("prune rewrites from the file, so an unloaded store cannot lose history")
    func pruneReadsTheFileNotJustMemory() throws {
        try withTemporaryDirectory { root in
            let a = sample(base, five: 1, seven: 1)
            let b = sample(base.addingTimeInterval(3600), five: 2, seven: 1)
            let c = sample(base.addingTimeInterval(7200), five: 3, seven: 1)
            let writer = makeStore(in: root)
            for s in [a, b, c] { try writer.append(s) }

            let unloaded = makeStore(in: root)
            let d = sample(base.addingTimeInterval(10800), five: 4, seven: 1)
            try unloaded.append(d)
            #expect(unloaded.samples == [d])

            let removed = try unloaded.prune(olderThan: base.addingTimeInterval(5400))
            #expect(removed == 2)
            #expect(unloaded.samples == [c, d])

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [c, d])
        }
    }

    @Test("prune on a missing file reports zero and creates nothing")
    func pruneMissingFile() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let removed = try store.prune(olderThan: base)
            #expect(removed == 0)
            #expect(!FileManager.default.fileExists(atPath: samplesURL(in: root).path))
        }
    }

    @Test("pruning rewrites away undecodable lines")
    func pruneHealsCorruptLines() throws {
        try withTemporaryDirectory { root in
            let encoder = JSONEncoder.claudeMeter()
            let old = sample(base, five: 1, seven: 1)
            let keep = sample(base.addingTimeInterval(7200), five: 2, seven: 1)
            var data = Data()
            data.append(try encoder.encode(old))
            data.append(0x0A)
            data.append(Data("{\"corrupt-marker\":".utf8))
            data.append(0x0A)
            data.append(try encoder.encode(keep))
            data.append(0x0A)
            try data.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            try store.load()
            let removed = try store.prune(olderThan: base.addingTimeInterval(3600))
            #expect(removed == 1)

            let text = try String(contentsOf: samplesURL(in: root), encoding: .utf8)
            #expect(!text.contains("corrupt-marker"))

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [keep])
        }
    }

    /// The damage-clearing half of `prune`. A file whose only problem is an
    /// undecodable line has nothing to *remove*, so keying the rewrite on the
    /// removed count alone would leave the garbage on disk permanently: once every
    /// real sample is newer than the cutoff, each later prune finds nothing to drop
    /// and skips the rewrite again.
    @Test("prune clears undecodable lines even when no sample is old enough to drop")
    func pruneHealsWithNothingToRemove() throws {
        try withTemporaryDirectory { root in
            let encoder = JSONEncoder.claudeMeter()
            let a = sample(base, five: 1, seven: 1)
            let b = sample(base.addingTimeInterval(600), five: 2, seven: 1)
            var data = Data()
            data.append(try encoder.encode(a))
            data.append(0x0A)
            data.append(Data("{\"corrupt-marker\":".utf8))
            data.append(0x0A)
            data.append(try encoder.encode(b))
            data.append(0x0A)
            try data.write(to: samplesURL(in: root))

            let store = makeStore(in: root)
            let removed = try store.prune(olderThan: base.addingTimeInterval(-1))
            #expect(removed == 0)
            #expect(store.samples == [a, b])

            let text = try String(contentsOf: samplesURL(in: root), encoding: .utf8)
            #expect(!text.contains("corrupt-marker"))
            #expect(text.split(separator: "\n").filter { !$0.isEmpty }.count == 2)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples == [a, b])
        }
    }

    @Test("appending after a prune continues the rewritten file")
    func appendAfterPrune() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            for i in 0..<3 {
                try store.append(sample(base.addingTimeInterval(TimeInterval(i) * 600), five: Double(i), seven: 2))
            }
            _ = try store.prune(olderThan: base.addingTimeInterval(600))
            let next = sample(base.addingTimeInterval(1800), five: 9, seven: 2)
            try store.append(next)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples.map(\.fiveHourPct) == [1, 2, 9])
        }
    }

    @Test("pruning the whole series leaves a readable empty file")
    func pruneEverything() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            try store.append(sample(base, five: 1, seven: 1))
            try store.append(sample(base.addingTimeInterval(600), five: 2, seven: 1))

            let removed = try store.prune(olderThan: base.addingTimeInterval(24 * 3600))
            #expect(removed == 2)
            #expect(store.samples.isEmpty)

            let reader = makeStore(in: root)
            try reader.load()
            #expect(reader.samples.isEmpty)

            let next = sample(base.addingTimeInterval(25 * 3600), five: 3, seven: 1)
            try reader.append(next)
            let third = makeStore(in: root)
            try third.load()
            #expect(third.samples == [next])
        }
    }

    // MARK: Snapshot cache

    @Test("snapshot cache round-trips, resetsAt included")
    func snapshotRoundTrip() throws {
        try withTemporaryDirectory { root in
            let fiveReset = base.addingTimeInterval(2 * 3600)
            let sevenReset = base.addingTimeInterval(4 * 24 * 3600)
            let snapshot = UsageSnapshot(
                fiveHour: LimitWindow(utilization: 17, resetsAt: fiveReset),
                sevenDay: LimitWindow(utilization: 7, resetsAt: sevenReset),
                limits: [
                    RateLimit(
                        kind: "session", group: "session", percent: 17, severity: .normal,
                        resetsAt: fiveReset, scopeLabel: nil, isActive: true),
                    RateLimit(
                        kind: "weekly_scoped", group: "weekly", percent: 3, severity: .normal,
                        resetsAt: sevenReset, scopeLabel: "Fable", isActive: true),
                ],
                extraUsage: ExtraUsage(isEnabled: false, utilization: nil, spendLimitReached: false),
                fetchedAt: base
            )

            let store = makeStore(in: root)
            try store.cacheSnapshot(snapshot)

            let loaded = makeStore(in: root).loadCachedSnapshot()
            #expect(loaded == snapshot)
            #expect(loaded?.fiveHour?.resetsAt == fiveReset)
            #expect(loaded?.sevenDay?.resetsAt == sevenReset)
            #expect(loaded?.limits.count == 2)
            #expect(loaded?.limits[1].scopeLabel == "Fable")
            #expect(loaded?.fetchedAt == base)
        }
    }

    @Test("a snapshot with absent windows round-trips as absent")
    func snapshotWithNilWindows() throws {
        try withTemporaryDirectory { root in
            let snapshot = UsageSnapshot(
                fiveHour: nil,
                sevenDay: LimitWindow(utilization: 93.5, resetsAt: nil),
                limits: [],
                extraUsage: nil,
                fetchedAt: base
            )
            let store = makeStore(in: root)
            try store.cacheSnapshot(snapshot)

            let loaded = store.loadCachedSnapshot()
            #expect(loaded?.fiveHour == nil)
            #expect(loaded?.sevenDay?.utilization == 93.5)
            #expect(loaded?.sevenDay?.resetsAt == nil)
            #expect(loaded?.extraUsage == nil)
            #expect(loaded?.limits.isEmpty == true)
        }
    }

    @Test("cacheSnapshot overwrites the previous cache rather than appending to it")
    func snapshotCacheOverwrites() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let first = UsageSnapshot(
                fiveHour: LimitWindow(utilization: 17, resetsAt: nil), sevenDay: nil,
                limits: [], extraUsage: nil, fetchedAt: base)
            let second = UsageSnapshot(
                fiveHour: LimitWindow(utilization: 42, resetsAt: nil), sevenDay: nil,
                limits: [], extraUsage: nil, fetchedAt: base.addingTimeInterval(300))
            try store.cacheSnapshot(first)
            try store.cacheSnapshot(second)
            #expect(store.loadCachedSnapshot() == second)
        }
    }

    @Test("loadCachedSnapshot returns nil when the file is missing")
    func loadCachedSnapshotMissingFile() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            #expect(!FileManager.default.fileExists(atPath: store.snapshotURL.path))
            #expect(store.loadCachedSnapshot() == nil)
        }
    }

    /// The launch path calls this before anything else, so every unusable file has
    /// to come back as `nil` rather than an error.
    @Test("loadCachedSnapshot returns nil for empty, truncated and wrong-schema files")
    func loadCachedSnapshotRejectsUnusableFiles() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            let payloads = [
                "",                                                              // empty file
                "{ not a snapshot",                                              // truncated JSON
                #"{"fiveHour":{"utilization":17,"#,                              // truncated mid-object
                #"{"limits":[]}"#,                                               // wrong schema: no fetchedAt
                #"{"fetchedAt":0,"limits":[],"fiveHour":{"utilization":"lots"}}"#, // wrong field type
                "[1,2,3]",                                                       // valid JSON, wrong shape
                "null",
            ]
            for payload in payloads {
                try Data(payload.utf8).write(to: store.snapshotURL)
                #expect(store.loadCachedSnapshot() == nil)
            }

            // Still usable once a good file lands.
            let good = UsageSnapshot(
                fiveHour: LimitWindow(utilization: 5, resetsAt: nil), sevenDay: nil,
                limits: [], extraUsage: nil, fetchedAt: base)
            try store.cacheSnapshot(good)
            #expect(store.loadCachedSnapshot() == good)
        }
    }

    /// A snapshot path that holds a directory instead of a file is the shape a
    /// half-finished migration or a stray `mkdir` leaves behind. `Data(contentsOf:)`
    /// throws on it, so this is the failure mode most likely to escape the `try?`.
    @Test("loadCachedSnapshot returns nil when a directory sits at the snapshot path")
    func loadCachedSnapshotDirectoryAtPath() throws {
        try withTemporaryDirectory { root in
            let store = makeStore(in: root)
            try FileManager.default.createDirectory(
                at: store.snapshotURL, withIntermediateDirectories: true)
            #expect(store.loadCachedSnapshot() == nil)
        }
    }

    // MARK: Directory creation

    /// True cold start: the support directory itself does not exist yet, which is
    /// the state of every first launch. Both read paths have to cope with an absent
    /// *parent*, not merely an absent file, and neither may create anything — the
    /// directory is made on the first write, not on the first look.
    @Test("reading before anything is written neither throws nor creates the directory")
    func coldStartReadsCreateNothing() throws {
        try withTemporaryDirectory { root in
            let absent = root.appending(path: "never/created")
            let store = SampleStore(
                samplesFile: absent.appending(path: "samples.jsonl"),
                snapshotFile: absent.appending(path: "last-snapshot.json")
            )

            try store.load()
            #expect(store.samples.isEmpty)
            #expect(store.samples(since: base).isEmpty)
            #expect(store.loadCachedSnapshot() == nil)

            let removed = try store.prune(olderThan: base)
            #expect(removed == 0)

            #expect(!FileManager.default.fileExists(atPath: absent.path))
        }
    }

    @Test("a missing parent directory is created on demand")
    func createsMissingParentDirectoryOnDemand() throws {
        try withTemporaryDirectory { root in
            let nested = root.appending(path: "one/two/three")
            #expect(!FileManager.default.fileExists(atPath: nested.path))

            let store = SampleStore(
                samplesFile: nested.appending(path: "samples.jsonl"),
                snapshotFile: nested.appending(path: "last-snapshot.json")
            )
            try store.append(sample(base, five: 1, seven: 1))
            try store.cacheSnapshot(
                UsageSnapshot(
                    fiveHour: LimitWindow(utilization: 1, resetsAt: nil), sevenDay: nil,
                    limits: [], extraUsage: nil, fetchedAt: base))

            #expect(FileManager.default.fileExists(atPath: store.samplesURL.path))
            #expect(FileManager.default.fileExists(atPath: store.snapshotURL.path))
        }
    }

    /// The one case that exercises the `Paths` defaults, and so the only one that
    /// touches the shared override. It holds the override for a single small write
    /// to keep the window in which a parallel suite could see it as short as
    /// possible.
    @Test("the default locations sit in the support directory and create it on demand")
    func defaultLocationsCreateSupportDirectory() throws {
        try withTemporaryDirectory { root in
            let nested = root.appending(path: "nested/ClaudeMeter")
            let previous = Paths.supportDirectoryOverride
            Paths.supportDirectoryOverride = nested
            defer { Paths.supportDirectoryOverride = previous }

            #expect(!FileManager.default.fileExists(atPath: nested.path))

            let store = SampleStore()
            // The override is process-global and the other suites in this target
            // clear it to `nil` in their own `defer`, so it can be torn out from
            // under the two lines above. If that happened, `store` resolved its
            // defaults against the *real* support directory and the append below
            // would drop a samples file into the user's home — fail here instead.
            try #require(store.samplesURL.path.hasPrefix(nested.path + "/"))
            #expect(store.samplesURL == nested.appending(path: "samples.jsonl"))
            #expect(store.snapshotURL == nested.appending(path: "last-snapshot.json"))

            try store.append(sample(base, five: 1, seven: 1))
            #expect(FileManager.default.fileExists(atPath: nested.path))
            #expect(FileManager.default.fileExists(atPath: store.samplesURL.path))
        }
    }
}
