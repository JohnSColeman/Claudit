import Foundation

/// Token counts for one API response.
public struct TokenUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// Everything the model read as input for this call (the "context size").
    public var contextSize: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }

    mutating func formMax(_ o: TokenUsage) {
        input = max(input, o.input)
        output = max(output, o.output)
        cacheRead = max(cacheRead, o.cacheRead)
        cacheWrite5m = max(cacheWrite5m, o.cacheWrite5m)
        cacheWrite1h = max(cacheWrite1h, o.cacheWrite1h)
    }
}

/// Rates that replace a model's standard ones for any request whose prompt is larger than `threshold` tokens.
/// The whole request is billed at these rates, not just the tokens past the threshold.
public struct LongContextPrice: Codable, Equatable, Sendable {
    public var threshold: Int
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(threshold: Int, input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.threshold = threshold
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }
}

/// Dollars per million tokens.
public struct ModelPrice: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    /// Higher rates for large prompts, for models that have them. Absent in tables saved by earlier versions.
    public var longContext: LongContextPrice?

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double,
                longContext: LongContextPrice? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.longContext = longContext
    }

    /// Standard multipliers: cache read 0.1x, 5-minute write 1.25x, 1-hour write 2x of the input price.
    public static func standard(input: Double, output: Double, cacheRead: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output,
                   cacheRead: cacheRead ?? input * 0.1,
                   cacheWrite5m: input * 1.25,
                   cacheWrite1h: input * 2)
    }
}

/// The three cost components of one response. "Carry" is re-reading existing context from cache;
/// "newInput" is fresh input plus cache writes; "output" is generated tokens.
public struct CostParts: Equatable, Sendable {
    public var carry: Double
    public var newInput: Double
    public var output: Double
    public var total: Double { carry + newInput + output }
}

/// Per-model prices plus the date they were last checked. Persisted by the app and editable in its UI.
public struct PriceTable: Codable, Equatable, Sendable {
    public var prices: [String: ModelPrice]
    /// When these prices were last confirmed or edited. Shown in the popover footer.
    public var asOf: Date

    public init(prices: [String: ModelPrice], asOf: Date = PriceTable.seedDate) {
        self.prices = prices
        self.asOf = asOf
    }

    /// The date the built-in defaults were taken from Anthropic's published model table.
    public static let seedDate: Date = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!

    /// Starting prices, used on first run and by "Reset to defaults". Taken from Anthropic's published pricing
    /// page; "Update from Anthropic" in the editor re-reads it.
    public static let builtIn = PriceTable(prices: [
        "claude-fable-5": .standard(input: 10, output: 50),
        "claude-fable-5-1": .standard(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5-2": .standard(input: 8, output: 40, cacheRead: 0.20),
        "claude-opus-5-5": .standard(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": .standard(input: 5, output: 25),
        "claude-opus-4-8": .standard(input: 5, output: 25),
        "claude-opus-4-7": .standard(input: 5, output: 25),
        "claude-opus-4-6": .standard(input: 5, output: 25),
        "claude-opus-4-5": .standard(input: 5, output: 25),
        "claude-opus-4-1": .standard(input: 15, output: 75),
        "claude-sonnet-5-5": .standard(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": .standard(input: 2, output: 10),
        "claude-sonnet-4-6": .standard(input: 3, output: 15),
        "claude-sonnet-4-5": .standard(input: 3, output: 15),
        "claude-haiku-5-5": ModelPrice(
            input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.20,
            longContext: LongContextPrice(threshold: 100_000, input: 0.50, output: 2.50,
                                          cacheRead: 0.05, cacheWrite5m: 0.625, cacheWrite1h: 1)),
        "claude-haiku-4-5": .standard(input: 1, output: 5),
    ])

    // MARK: Persistence (the app's own storage, shared with the command-line report)

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claudit")
    }
    public static var storeURL: URL { supportDirectory.appendingPathComponent("price-table.json") }
    /// Earlier versions kept a plain {model: price} override file here. It is merged in once, on first run.
    public static var legacyOverridesURL: URL { supportDirectory.appendingPathComponent("prices.json") }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Loads the saved table. On first run it seeds from `builtIn` (merging any legacy override file) and saves it.
    /// An unreadable file falls back to the defaults without overwriting it, so it can be repaired by hand.
    public static func load(from url: URL = storeURL, legacy: URL = legacyOverridesURL) -> PriceTable {
        if let data = try? Data(contentsOf: url) {
            return (try? makeDecoder().decode(PriceTable.self, from: data)) ?? builtIn
        }
        var table = builtIn
        if let data = try? Data(contentsOf: legacy),
           let overrides = try? JSONDecoder().decode([String: ModelPrice].self, from: data) {
            for (k, v) in overrides { table.prices[k] = v }
        }
        try? table.save(to: url)
        return table
    }

    public func save(to url: URL = PriceTable.storeURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func price(for model: String) -> ModelPrice? {
        if let p = prices[model] { return p }
        var best: (key: String, price: ModelPrice)?
        for (k, v) in prices where model.hasPrefix(k + "-") || model.hasPrefix(k + "@") {
            if best == nil || k.count > best!.key.count { best = (k, v) }
        }
        return best?.price
    }

    public func cost(of u: TokenUsage, model: String) -> CostParts? {
        guard let price = price(for: model) else { return nil }
        var p = price
        if let l = price.longContext, u.contextSize > l.threshold {
            p = ModelPrice(input: l.input, output: l.output, cacheRead: l.cacheRead,
                           cacheWrite5m: l.cacheWrite5m, cacheWrite1h: l.cacheWrite1h)
        }
        let m = 1_000_000.0
        return CostParts(
            carry: Double(u.cacheRead) * p.cacheRead / m,
            newInput: (Double(u.input) * p.input + Double(u.cacheWrite5m) * p.cacheWrite5m
                       + Double(u.cacheWrite1h) * p.cacheWrite1h) / m,
            output: Double(u.output) * p.output / m)
    }
}
