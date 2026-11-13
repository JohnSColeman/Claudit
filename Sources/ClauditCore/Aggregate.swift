import Foundation

public enum Activity: String, CaseIterable, Sendable {
    case chat = "Conversation"
    case explore = "Exploring code"
    case implement = "Implementing"
    case run = "Running commands"
    case research = "Web research"
    case connectors = "Connectors (MCP)"
    case delegate = "Subagents"

    public var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .explore: return "magnifyingglass"
        case .implement: return "hammer"
        case .run: return "terminal"
        case .research: return "globe"
        case .connectors: return "puzzlepiece.extension"
        case .delegate: return "person.2"
        }
    }
}

public struct CostBreakdown: Equatable, Sendable {
    /// Re-reading existing context from the cache on every turn.
    public var carry = 0.0
    /// Fresh input tokens plus cache writes.
    public var newInput = 0.0
    /// Tokens the model generated (main thread).
    public var output = 0.0
    /// Everything spent inside subagents.
    public var subagent = 0.0

    public init() {}
    public var total: Double { carry + newInput + output + subagent }

    static func + (a: CostBreakdown, b: CostBreakdown) -> CostBreakdown {
        var r = CostBreakdown()
        r.carry = a.carry + b.carry
        r.newInput = a.newInput + b.newInput
        r.output = a.output + b.output
        r.subagent = a.subagent + b.subagent
        return r
    }
    static func += (a: inout CostBreakdown, b: CostBreakdown) { a = a + b }
}

/// Everything Claude did in response to one user prompt.
public struct PromptCost: Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let project: String
    public let text: String
    public let start: Date
    public var end: Date
    public var cost = CostBreakdown()
    public var turns = 0
    public var subagentTurns = 0
    public var toolCounts: [String: Int] = [:]
    public var maxContext = 0
    public var modelCost: [String: Double] = [:]
    public var activity: Activity = .chat
    public var isContinuation = false

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum Aggregator {
    static let exploreTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "LSP"]
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let runTools: Set<String> = ["Bash", "BashOutput", "KillShell", "Monitor"]
    static let webTools: Set<String> = ["WebFetch", "WebSearch"]

    public static func classify(_ p: PromptCost) -> Activity {
        let total = p.cost.total
        if total > 0, p.cost.subagent / total > 0.5 { return .delegate }
        var explore = 0, edit = 0, run = 0, web = 0, mcp = 0
        for (name, n) in p.toolCounts {
            if editTools.contains(name) { edit += n }
            else if runTools.contains(name) { run += n }
            else if exploreTools.contains(name) { explore += n }
            else if webTools.contains(name) { web += n }
            else if name.hasPrefix("mcp__") { mcp += n }
        }
        if edit > 0 { return .implement }
        let best = max(run, explore, web, mcp)
        if best == 0 { return .chat }
        if run == best { return .run }
        if explore == best { return .explore }
        if web == best { return .research }
        return .connectors
    }

    /// Groups transcript files by session, assigns every (deduplicated) assistant message to the prompt that
    /// was active at that moment, and prices it. Subagent transcripts are attributed to the parent prompt.
    public static func prompts(from files: [SessionFileState], prices: PriceTable)
        -> (prompts: [PromptCost], unpriced: Set<String>) {
        var unpriced = Set<String>()
        var out: [PromptCost] = []

        let groups = Dictionary(grouping: files, by: \.groupKey)

        // A resumed or continued session copies earlier messages into its own transcript, so the same
        // message id can appear in several sessions. Count each one once, under the session that started first.
        func firstTime(_ g: [SessionFileState]) -> Date {
            g.flatMap { $0.messages.values.map(\.timestamp) }.min() ?? .distantFuture
        }
        let order = groups.sorted { a, b in
            let (ta, tb) = (firstTime(a.value), firstTime(b.value))
            return ta != tb ? ta < tb : a.key < b.key
        }
        var owner: [String: String] = [:]
        var merged: [String: TokenUsage] = [:]
        for (groupKey, group) in order {
            for m in group.flatMap({ $0.messages.values }) {
                if owner[m.key] == nil { owner[m.key] = groupKey; merged[m.key] = m.usage }
                else { merged[m.key]!.formMax(m.usage) }
            }
        }

        for (groupKey, group) in order {
            let main = group.first { !$0.isSubagent }
            let project = (main ?? group[0]).projectName
            let sessionId = group[0].sessionId
            let starts = (main?.prompts ?? []).sorted { $0.timestamp < $1.timestamp }
            let times = starts.map(\.timestamp)

            var buckets = starts.map {
                PromptCost(id: $0.id, sessionId: sessionId, project: project, text: $0.text,
                           start: $0.timestamp, end: $0.timestamp)
            }
            var pre: PromptCost?

            func index(for t: Date) -> Int? {
                var lo = 0, hi = times.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if times[mid] <= t { lo = mid + 1 } else { hi = mid }
                }
                return lo - 1 >= 0 ? lo - 1 : nil
            }

            let messages = group.flatMap { $0.messages.values }.filter { owner[$0.key] == groupKey }
                .sorted { $0.timestamp < $1.timestamp }
            for var m in messages {
                m.usage = merged[m.key] ?? m.usage
                let parts = prices.cost(of: m.usage, model: m.model)
                if parts == nil { unpriced.insert(m.model) }
                let c = parts ?? CostParts(carry: 0, newInput: 0, output: 0)

                func apply(_ p: inout PromptCost) {
                    p.turns += 1
                    p.end = max(p.end, m.timestamp)
                    if m.isSubagent {
                        p.cost.subagent += c.total
                        p.subagentTurns += 1
                    } else {
                        p.cost.carry += c.carry
                        p.cost.newInput += c.newInput
                        p.cost.output += c.output
                        p.maxContext = max(p.maxContext, m.usage.contextSize)
                        for name in m.tools.values { p.toolCounts[name, default: 0] += 1 }
                    }
                    p.modelCost[m.model, default: 0] += c.total
                }

                if let i = index(for: m.timestamp) {
                    apply(&buckets[i])
                } else {
                    if pre == nil {
                        pre = PromptCost(id: "pre-" + groupKey, sessionId: sessionId, project: project,
                                         text: "(earlier in this session)", start: m.timestamp, end: m.timestamp,
                                         isContinuation: true)
                    }
                    apply(&pre!)
                }
            }

            if let pre { buckets.append(pre) }
            for var b in buckets where b.turns > 0 {
                b.activity = classify(b)
                out.append(b)
            }
        }
        return (out.sorted { $0.start < $1.start }, unpriced)
    }
}

public struct NamedTotal: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var cost: Double
    public var count: Int
}

public struct ActivityTotal: Identifiable, Sendable {
    public var id: String { activity.rawValue }
    public let activity: Activity
    public var cost: CostBreakdown
    public var count: Int
}

public struct Report: Sendable {
    public var interval: DateInterval
    public var total = CostBreakdown()
    /// Sorted most expensive first.
    public var prompts: [PromptCost] = []
    public var byActivity: [ActivityTotal] = []
    public var byProject: [NamedTotal] = []
    public var byModel: [NamedTotal] = []
    public var insights: [String] = []
    public var unpricedModels: [String] = []
    public var generated = Date()

    public static func make(prompts all: [PromptCost], interval: DateInterval, unpriced: Set<String> = []) -> Report {
        var r = Report(interval: interval)
        r.unpricedModels = unpriced.sorted()
        let inRange = all.filter { interval.contains($0.start) }
        r.prompts = inRange.sorted { $0.cost.total > $1.cost.total }
        for p in inRange { r.total += p.cost }

        var act: [Activity: ActivityTotal] = [:]
        var proj: [String: NamedTotal] = [:]
        var model: [String: NamedTotal] = [:]
        for p in inRange {
            var a = act[p.activity] ?? ActivityTotal(activity: p.activity, cost: CostBreakdown(), count: 0)
            a.cost += p.cost
            a.count += 1
            act[p.activity] = a
            var pr = proj[p.project] ?? NamedTotal(name: p.project, cost: 0, count: 0)
            pr.cost += p.cost.total
            pr.count += 1
            proj[p.project] = pr
            for (m, c) in p.modelCost {
                var mt = model[m] ?? NamedTotal(name: m, cost: 0, count: 0)
                mt.cost += c
                mt.count += 1
                model[m] = mt
            }
        }
        r.byActivity = act.values.sorted { $0.cost.total > $1.cost.total }
        r.byProject = proj.values.sorted { $0.cost > $1.cost }
        r.byModel = model.values.sorted { $0.cost > $1.cost }
        r.insights = insights(for: r)
        return r
    }

    static func insights(for r: Report) -> [String] {
        let total = r.total.total
        guard total > 0 else { return [] }
        var out: [String] = []
        let carryShare = r.total.carry / total
        let maxCtx = r.prompts.map(\.maxContext).max() ?? 0
        if carryShare > 0.5 {
            var s = "\(Int((carryShare * 100).rounded()))% of spend is context carry: the whole history re-read on every turn."
            if maxCtx > 100_000 { s += " Context peaked at \(maxCtx / 1000)k tokens; /clear or /compact between tasks." }
            out.append(s)
        }
        let writeShare = r.total.newInput / total
        if writeShare > 0.5 {
            out.append("\(Int((writeShare * 100).rounded()))% of spend is new context being written to cache: file reads, command output and pasted content. Trimming tool output (filtered test/build logs) saves the most.")
        }
        if let top = r.prompts.first, top.cost.total / total > 0.10, r.prompts.count > 3 {
            out.append("Most expensive prompt took \(Int((top.cost.total / total * 100).rounded()))% of the total: \"\(top.text.prefix(60))\" (\(top.turns) turns).")
        }
        let subShare = r.total.subagent / total
        if subShare > 0.2 {
            out.append("Subagents account for \(Int((subShare * 100).rounded()))% of spend.")
        }
        if let m = r.byModel.first, m.cost / total > 0.6, r.byModel.count > 1 {
            out.append("\(Int((m.cost / total * 100).rounded()))% of spend ran on \(m.name).")
        }
        return out
    }
}

public enum Money {
    public static func format(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 0.095 || v == 0 { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }
}
