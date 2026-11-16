import Foundation

/// Tracks every Claude Code transcript under ~/.claude/projects and parses only newly appended lines.
/// Not thread-safe: call from a single queue.
public final class TranscriptStore {
    public let root: URL
    private var files: [String: SessionFileState] = [:]

    /// Why the last scan could not read transcripts, or nil if it went fine.
    public private(set) var lastError: String?

    /// Claude Code keeps transcripts under $CLAUDE_CONFIG_DIR/projects when that is set, else ~/.claude/projects.
    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public init(root: URL = TranscriptStore.defaultRoot) {
        self.root = root
    }

    public var sessions: [SessionFileState] { Array(files.values) }

    /// Scans for new or grown transcripts. Files untouched since `since` are ignored unless already tracked.
    /// Returns true if any new data was ingested.
    @discardableResult
    public func refresh(since: Date) -> Bool {
        let fm = FileManager.default
        lastError = nil
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            lastError = "No transcript folder at \(root.path). Claude Code may store its data elsewhere on this Mac, or access to the folder is blocked."
            return false
        }
        var firstFailure: String?
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { url, error in
                                         if firstFailure == nil { firstFailure = "\(url.path): \(error.localizedDescription)" }
                                         return true
                                     }) else {
            lastError = "Could not read \(root.path). Check that Claudit is allowed to access it."
            return false
        }
        defer {
            if let firstFailure { lastError = "Some transcripts could not be read (\(firstFailure)). Access may be blocked by macOS privacy settings or a device policy." }
        }
        var changed = false
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            let path = url.path
            let size = UInt64(v.fileSize ?? 0)

            if let state = files[path] {
                if size < state.offset { state.reset() }
                if size == state.offset { continue }
                if state.readNew() { changed = true }
            } else {
                guard let mtime = v.contentModificationDate, mtime >= since, size > 0 else { continue }
                guard let state = makeState(for: url) else { continue }
                do { try FileHandle(forReadingFrom: url).close() } catch {
                    if firstFailure == nil { firstFailure = "\(path): \(error.localizedDescription)" }
                    continue
                }
                files[path] = state
                if state.readNew() { changed = true }
            }
        }
        return changed
    }

    private func makeState(for url: URL) -> SessionFileState? {
        // <root>/<projectDir>/<sessionId>.jsonl   or   <root>/<projectDir>/<sessionId>/subagents/agent-x.jsonl
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count + 1 else { return nil }
        let rel = Array(parts[rootParts.count...])
        if rel.count == 2 {
            return SessionFileState(url: url, projectDir: rel[0], sessionId: (rel[1] as NSString).deletingPathExtension, isSubagent: false)
        }
        if rel.count >= 4, rel[2] == "subagents" {
            return SessionFileState(url: url, projectDir: rel[0], sessionId: rel[1], isSubagent: true)
        }
        return nil
    }
}
