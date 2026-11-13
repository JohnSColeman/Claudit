import Foundation

/// Tracks every Claude Code transcript under ~/.claude/projects and parses only newly appended lines.
/// Not thread-safe: call from a single queue.
public final class TranscriptStore {
    public let root: URL
    private var files: [String: SessionFileState] = [:]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    public var sessions: [SessionFileState] { Array(files.values) }

    /// Scans for new or grown transcripts. Files untouched since `since` are ignored unless already tracked.
    /// Returns true if any new data was ingested.
    @discardableResult
    public func refresh(since: Date) -> Bool {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return false }
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
