import Foundation

public struct PromptStart: Sendable {
    public let id: String
    public let timestamp: Date
    public let text: String
}

public struct MessageRecord: Sendable {
    public var key: String
    public var model: String
    public var timestamp: Date
    public var usage: TokenUsage
    /// tool_use id -> tool name. A streamed message is logged once per content block, so these accumulate.
    public var tools: [String: String]
    public var isSubagent: Bool
}

/// Incrementally parsed state of one Claude Code transcript (.jsonl) file.
public final class SessionFileState {
    public let url: URL
    public let projectDir: String
    public let sessionId: String
    public let isSubagent: Bool
    public private(set) var cwd: String?
    public private(set) var prompts: [PromptStart] = []
    /// Deduplicated assistant messages. The same message appears on several lines while streaming.
    public private(set) var messages: [String: MessageRecord] = [:]
    public internal(set) var offset: UInt64 = 0

    public init(url: URL, projectDir: String, sessionId: String, isSubagent: Bool) {
        self.url = url
        self.projectDir = projectDir
        self.sessionId = sessionId
        self.isSubagent = isSubagent
    }

    public var groupKey: String { projectDir + "/" + sessionId }

    public var projectName: String {
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return projectDir
    }

    func reset() {
        prompts = []
        messages = [:]
        offset = 0
        cwd = nil
    }

    /// Reads any complete new lines appended since the last call. Returns true if anything was consumed.
    @discardableResult
    func readNew() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return false }
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return false }
            let consumed = data[data.startIndex...lastNewline]
            ingest(chunk: Data(consumed))
            offset += UInt64(consumed.count)
            return true
        } catch {
            return false
        }
    }

    /// Ingests complete newline-separated JSON lines.
    public func ingest(chunk: Data) {
        for line in chunk.split(separator: 0x0A, omittingEmptySubsequences: true) {
            ingestLine(Data(line))
        }
    }

    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let userMarker = Data("\"type\":\"user\"".utf8)

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    func ingestLine(_ line: Data) {
        let isAssistant = line.range(of: Self.assistantMarker) != nil
        let isUser = !isAssistant && line.range(of: Self.userMarker) != nil
        guard isAssistant || isUser else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let ts = Self.parseDate(tsString) else { return }

        if cwd == nil, let c = obj["cwd"] as? String { cwd = c }

        if isAssistant, (obj["type"] as? String) == "assistant" {
            ingestAssistant(obj, ts: ts)
        } else if isUser, (obj["type"] as? String) == "user", !isSubagent {
            ingestUser(obj, ts: ts)
        }
    }

    private func ingestAssistant(_ obj: [String: Any], ts: Date) {
        guard let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>" else { return }

        func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        var u = TokenUsage(input: int(usage, "input_tokens"),
                           output: int(usage, "output_tokens"),
                           cacheRead: int(usage, "cache_read_input_tokens"))
        let totalWrite = int(usage, "cache_creation_input_tokens")
        if let cc = usage["cache_creation"] as? [String: Any] {
            u.cacheWrite5m = int(cc, "ephemeral_5m_input_tokens")
            u.cacheWrite1h = int(cc, "ephemeral_1h_input_tokens")
            let split = u.cacheWrite5m + u.cacheWrite1h
            if split < totalWrite { u.cacheWrite5m += totalWrite - split }
        } else {
            u.cacheWrite5m = totalWrite
        }

        let id = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        let key = id + "|" + ((obj["requestId"] as? String) ?? "")

        var tools: [String: String] = [:]
        if let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "tool_use" {
                if let tid = b["id"] as? String, let name = b["name"] as? String { tools[tid] = name }
            }
        }

        if var existing = messages[key] {
            existing.usage.formMax(u)
            existing.tools.merge(tools) { a, _ in a }
            existing.timestamp = min(existing.timestamp, ts)
            messages[key] = existing
        } else {
            messages[key] = MessageRecord(key: key, model: model, timestamp: ts, usage: u,
                                          tools: tools, isSubagent: isSubagent)
        }
    }

    private func ingestUser(_ obj: [String: Any], ts: Date) {
        if (obj["isSidechain"] as? Bool) == true || (obj["isMeta"] as? Bool) == true { return }
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" { return }
        guard let msg = obj["message"] as? [String: Any] else { return }

        var raw: String?
        if let s = msg["content"] as? String {
            raw = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            if arr.contains(where: { ($0["type"] as? String) == "tool_result" }) { return }
            raw = (arr.first { ($0["type"] as? String) == "text" })?["text"] as? String ?? "[image]"
        }
        guard let text = Self.displayText(raw) else { return }
        let id = (obj["promptId"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        prompts.append(PromptStart(id: id, timestamp: ts, text: text))
    }

    /// Turns raw prompt content into a short single-line label, or nil if it is not a real prompt.
    static func displayText(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("[Request interrupted") || s.hasPrefix("<local-command") || s.hasPrefix("Caveat:") { return nil }
        if let a = s.range(of: "<command-name>"), let b = s.range(of: "</command-name>"), a.upperBound <= b.lowerBound {
            var cmd = String(s[a.upperBound..<b.lowerBound])
            if let x = s.range(of: "<command-args>"), let y = s.range(of: "</command-args>"), x.upperBound <= y.lowerBound {
                cmd += " " + s[x.upperBound..<y.lowerBound]
            }
            s = cmd
        }
        s = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        return s.count > 110 ? String(s.prefix(110)) + "…" : s
    }
}
