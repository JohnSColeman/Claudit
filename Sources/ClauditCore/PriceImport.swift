import Foundation

/// One model whose price on Anthropic's page differs from the current table (or is missing from it).
public struct PriceChange: Identifiable, Equatable, Sendable {
    public var id: String { model }
    public let model: String
    public let old: ModelPrice?
    public let new: ModelPrice

    public var isNew: Bool { old == nil }

    /// Short human description of what differs, e.g. "cache read 1 → 0.25".
    public var summary: String {
        guard let old else { return "new model" }
        func g(_ v: Double) -> String { String(format: "%g", v) }
        var parts: [String] = []
        let fields: [(String, Double, Double)] = [
            ("input", old.input, new.input), ("output", old.output, new.output),
            ("cache read", old.cacheRead, new.cacheRead),
            ("write 5m", old.cacheWrite5m, new.cacheWrite5m), ("write 1h", old.cacheWrite1h, new.cacheWrite1h),
        ]
        for (name, a, b) in fields where !PriceImport.close(a, b) { parts.append("\(name) \(g(a)) → \(g(b))") }
        switch (old.longContext, new.longContext) {
        case (nil, let n?): parts.append("adds rates for prompts over \(n.threshold) tokens")
        case (_?, nil): parts.append("drops the long-prompt rates")
        case (let o?, let n?) where !PriceImport.close(o, n): parts.append("long-prompt rates change")
        default: break
        }
        return parts.joined(separator: ", ")
    }
}

/// Reads the model price table from Anthropic's pricing page (served as markdown) so the app's table can be refreshed.
public enum PriceImport {
    public static let pageURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!

    public struct Parsed: Sendable {
        /// Prices keyed by API model ID, e.g. "claude-opus-5-5".
        public var prices: [String: ModelPrice] = [:]
        /// Table rows that couldn't be turned into a model ID or a full set of prices.
        public var skipped: [String] = []
    }

    /// Parses the "Model pricing" table: Model | Base input | 5m writes | 1h writes | Cache hits and refreshes | Output.
    /// A model priced by prompt length appears as two rows ("for prompts up to N tokens" / "over N tokens").
    public static func parse(markdown: String) -> Parsed {
        var result = Parsed()
        let lines = markdown.components(separatedBy: .newlines)
        guard let header = lines.firstIndex(where: { $0.contains("Base input tokens") && $0.contains("Cache hits") }) else {
            return result
        }
        var base: [String: ModelPrice] = [:]
        var long: [String: LongContextPrice] = [:]

        for line in lines[(header + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|") else { break }
            if t.contains(":--") || t.contains("---") { continue }
            let cells = t.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 6 else { result.skipped.append(t); continue }

            let label = cells[0]
            guard let id = modelID(forLabel: label) else { result.skipped.append(label); continue }
            let nums = cells[1...].map(dollars)
            guard nums.allSatisfy({ $0 != nil }) else { result.skipped.append(label); continue }
            let (input, w5, w1, read, output) = (nums[0]!, nums[1]!, nums[2]!, nums[3]!, nums[4]!)

            if let tier = promptTier(in: label), tier.over {
                long[id] = LongContextPrice(threshold: tier.tokens, input: input, output: output,
                                            cacheRead: read, cacheWrite5m: w5, cacheWrite1h: w1)
            } else {
                base[id] = ModelPrice(input: input, output: output, cacheRead: read, cacheWrite5m: w5, cacheWrite1h: w1)
            }
        }
        for (id, l) in long where base[id] == nil { result.skipped.append("\(id) (long-prompt row without a base row)"); long[id] = nil }
        for (id, var p) in base { p.longContext = long[id]; result.prices[id] = p }
        return result
    }

    /// Models in `parsed` that are missing from `table` or priced differently, sorted by ID.
    public static func changes(from parsed: [String: ModelPrice], against table: [String: ModelPrice]) -> [PriceChange] {
        parsed.keys.sorted().compactMap { id in
            let new = parsed[id]!
            if let old = table[id], close(old, new) { return nil }
            return PriceChange(model: id, old: table[id], new: new)
        }
    }

    // MARK: Helpers

    /// "Claude Opus 4.1 ([retired…](url))" -> "claude-opus-4-1". Only "Claude <Family> <version>" names are mapped.
    static func modelID(forLabel label: String) -> String? {
        let name = label.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        guard name.range(of: #"^Claude [A-Za-z]+ [0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return name.lowercased().replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: " ", with: "-")
    }

    private static func promptTier(in label: String) -> (over: Bool, tokens: Int)? {
        guard let r = label.range(of: #"for prompts (up to|over) ([0-9,]+) tokens"#, options: .regularExpression) else { return nil }
        let words = label[r].split(separator: " ")
        guard let n = Int(words[words.count - 2].replacingOccurrences(of: ",", with: "")) else { return nil }
        return (words[2] == "over", n)
    }

    /// "$12.50 / MTok<sup>1</sup>" -> 12.5
    private static func dollars(_ cell: String) -> Double? {
        guard let r = cell.range(of: #"\$\s*[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return Double(cell[r].dropFirst().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
    }

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    static func close(_ a: LongContextPrice, _ b: LongContextPrice) -> Bool {
        a.threshold == b.threshold && close(a.input, b.input) && close(a.output, b.output)
            && close(a.cacheRead, b.cacheRead) && close(a.cacheWrite5m, b.cacheWrite5m) && close(a.cacheWrite1h, b.cacheWrite1h)
    }

    static func close(_ a: ModelPrice, _ b: ModelPrice) -> Bool {
        let longSame: Bool
        switch (a.longContext, b.longContext) {
        case (nil, nil): longSame = true
        case (let x?, let y?): longSame = close(x, y)
        default: longSame = false
        }
        return longSame && close(a.input, b.input) && close(a.output, b.output) && close(a.cacheRead, b.cacheRead)
            && close(a.cacheWrite5m, b.cacheWrite5m) && close(a.cacheWrite1h, b.cacheWrite1h)
    }
}
