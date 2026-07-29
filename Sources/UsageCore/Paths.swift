import Foundation

/// Every filesystem location the app touches. Centralised so tests can redirect
/// the support directory and so no module invents its own path convention.
public enum Paths {
    /// Overridable for tests. When set, all app-support files live here instead.
    nonisolated(unsafe) public static var supportDirectoryOverride: URL?

    /// Overridable for tests. When set, transcript scanning reads from here.
    nonisolated(unsafe) public static var claudeProjectsOverride: URL?

    /// `~/Library/Application Support/ClaudeMeter`, created on demand.
    public static var supportDirectory: URL {
        if let override = supportDirectoryOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "ClaudeMeter")
    }

    /// `~/.claude/projects` — the transcript root.
    public static var claudeProjects: URL {
        if let override = claudeProjectsOverride { return override }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
    }

    /// Append-only series of poll observations; the burn-rate dataset.
    public static var samplesFile: URL { supportDirectory.appending(path: "samples.jsonl") }

    /// Per-file byte offsets for incremental transcript scanning.
    public static var scanStateFile: URL { supportDirectory.appending(path: "scan-state.json") }

    /// Last successful usage snapshot, so the UI has something to show offline.
    public static var cachedSnapshotFile: URL { supportDirectory.appending(path: "last-snapshot.json") }

    /// Deduplicated transcript events, so a cold start doesn't re-read the whole corpus.
    public static var eventCacheFile: URL { supportDirectory.appending(path: "events.json") }

    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
