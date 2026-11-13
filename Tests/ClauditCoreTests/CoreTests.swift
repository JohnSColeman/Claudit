import XCTest
@testable import ClauditCore

final class CoreTests: XCTestCase {
    private func state(_ name: String = "s1", sub: Bool = false, session: String = "s1") -> SessionFileState {
        SessionFileState(url: URL(fileURLWithPath: "/tmp/\(name).jsonl"), projectDir: "proj", sessionId: session, isSubagent: sub)
    }

    private func user(_ text: String, ts: String, extra: String = "") -> String {
        "{\"type\":\"user\",\"promptId\":\"p-\(ts)\",\"timestamp\":\"\(ts)\",\"cwd\":\"/x/demo\",\(extra)\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    private func assistant(id: String, ts: String, model: String = "claude-sonnet-5-5",
                           input: Int = 0, output: Int = 0, read: Int = 0, write1h: Int = 0, tool: String? = nil) -> String {
        let content = tool.map { "[{\"type\":\"tool_use\",\"id\":\"t-\(id)\",\"name\":\"\($0)\"}]" } ?? "[{\"type\":\"text\",\"text\":\"hi\"}]"
        return "{\"type\":\"assistant\",\"requestId\":\"r-\(id)\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"content\":\(content),\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(read),\"cache_creation_input_tokens\":\(write1h),\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":\(write1h)}}}}"
    }

    func testDedupesStreamedMessagesAndPrices() {
        let s = state()
        let lines = [
            user("fix the bug", ts: "2026-11-13T10:00:00.000Z"),
            assistant(id: "m1", ts: "2026-11-13T10:00:01.000Z", input: 2, output: 10, read: 1_000_000),
            assistant(id: "m1", ts: "2026-11-13T10:00:02.000Z", input: 2, output: 500_000, read: 1_000_000, tool: "Edit"),
        ].joined(separator: "\n") + "\n"
        s.ingest(chunk: Data(lines.utf8))
        XCTAssertEqual(s.messages.count, 1)

        let (prompts, unpriced) = Aggregator.prompts(from: [s], prices: .builtIn)
        XCTAssertTrue(unpriced.isEmpty)
        XCTAssertEqual(prompts.count, 1)
        let p = prompts[0]
        // Sonnet 5.5: cache read $0.10/M -> $0.10; output $10/M * 0.5M -> $5.00
        XCTAssertEqual(p.cost.carry, 0.10, accuracy: 1e-9)
        XCTAssertEqual(p.cost.output, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.activity, .implement)
        XCTAssertEqual(p.project, "demo")
        XCTAssertEqual(p.text, "fix the bug")
    }

    func testMessageCopiedIntoResumedSessionIsCountedOnce() {
        let original = state("orig", session: "s1")
        let resumed = state("resumed", session: "s2")
        let first = [user("first", ts: "2026-11-13T10:00:00.000Z"),
                     assistant(id: "m1", ts: "2026-11-13T10:00:01.000Z", output: 1_000_000)].joined(separator: "\n") + "\n"
        original.ingest(chunk: Data(first.utf8))
        // Resuming copies the earlier history into a new transcript, then continues it.
        let second = first + [user("second", ts: "2026-11-13T11:00:00.000Z"),
                              assistant(id: "m2", ts: "2026-11-13T11:00:01.000Z", output: 1_000_000)].joined(separator: "\n") + "\n"
        resumed.ingest(chunk: Data(second.utf8))

        let (prompts, _) = Aggregator.prompts(from: [original, resumed], prices: .builtIn)
        // Sonnet 5.5 output $10/M: two distinct messages, not three.
        XCTAssertEqual(prompts.reduce(0) { $0 + $1.cost.total }, 20.0, accuracy: 1e-9)
    }

    func testLongContextRatesApplyOnlyAbovePromptThreshold() throws {
        var table = PriceTable.builtIn
        table.prices["tier"] = ModelPrice(
            input: 1, output: 2, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2,
            longContext: LongContextPrice(threshold: 100_000, input: 3, output: 6, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6))
        // Exactly at the threshold is still the standard tier; the prompt is input + cache read + cache writes.
        let atLimit = try XCTUnwrap(table.cost(of: TokenUsage(input: 50_000, output: 1_000_000, cacheRead: 50_000), model: "tier"))
        XCTAssertEqual(atLimit.output, 2.0, accuracy: 1e-9)
        XCTAssertEqual(atLimit.newInput, 0.05, accuracy: 1e-9)
        // Over it, the whole request is billed at the long-context rates.
        let over = try XCTUnwrap(table.cost(of: TokenUsage(input: 50_000, output: 1_000_000, cacheRead: 50_001), model: "tier"))
        XCTAssertEqual(over.output, 6.0, accuracy: 1e-9)
        XCTAssertEqual(over.newInput, 0.15, accuracy: 1e-9)
        XCTAssertEqual(over.carry, 50_001 * 0.3 / 1e6, accuracy: 1e-9)
        // Tables saved before this feature have no longContext key and must still load.
        let old = #"{"input":1,"output":2,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}"#
        XCTAssertNil(try JSONDecoder().decode(ModelPrice.self, from: Data(old.utf8)).longContext)
    }

    func testToolResultsAreNotPromptsAndMessagesSplitByPrompt() {
        let s = state()
        let toolResult = "{\"type\":\"user\",\"timestamp\":\"2026-11-13T10:00:03.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\",\"content\":\"ok\"}]}}"
        let lines = [
            user("first", ts: "2026-11-13T10:00:00.000Z"),
            assistant(id: "a", ts: "2026-11-13T10:00:01.000Z", output: 1000),
            toolResult,
            assistant(id: "b", ts: "2026-11-13T10:00:04.000Z", output: 1000),
            user("second", ts: "2026-11-13T10:05:00.000Z"),
            assistant(id: "c", ts: "2026-11-13T10:05:01.000Z", output: 1000),
        ].joined(separator: "\n") + "\n"
        s.ingest(chunk: Data(lines.utf8))
        let (prompts, _) = Aggregator.prompts(from: [s], prices: .builtIn)
        XCTAssertEqual(prompts.map(\.text), ["first", "second"])
        XCTAssertEqual(prompts.map(\.turns), [2, 1])
    }

    func testSubagentCostGoesToParentPromptAsSubagent() {
        let main = state()
        let sub = state("agent-1", sub: true)
        main.ingest(chunk: Data((user("research", ts: "2026-11-13T10:00:00.000Z") + "\n").utf8))
        main.ingest(chunk: Data((assistant(id: "m", ts: "2026-11-13T10:00:01.000Z", output: 1000) + "\n").utf8))
        sub.ingest(chunk: Data((assistant(id: "s", ts: "2026-11-13T10:00:02.000Z", output: 1_000_000) + "\n").utf8))
        let (prompts, _) = Aggregator.prompts(from: [main, sub], prices: .builtIn)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].cost.subagent, 10.0, accuracy: 1e-9)
        XCTAssertEqual(prompts[0].subagentTurns, 1)
        XCTAssertEqual(prompts[0].activity, .delegate)
    }

    func testUnpricedModelIsReportedNotSilentlyZero() {
        let s = state()
        s.ingest(chunk: Data((user("hi", ts: "2026-11-13T10:00:00.000Z") + "\n"
                              + assistant(id: "m", ts: "2026-11-13T10:00:01.000Z", model: "claude-mystery-9", output: 10) + "\n").utf8))
        let (_, unpriced) = Aggregator.prompts(from: [s], prices: .builtIn)
        XCTAssertEqual(unpriced, ["claude-mystery-9"])
    }

    func testPriceLookupHandlesDatedSuffixAndLongestPrefix() {
        XCTAssertEqual(PriceTable.builtIn.price(for: "claude-opus-5-5-20261101")?.input, 4)
        XCTAssertEqual(PriceTable.builtIn.price(for: "claude-opus-5")?.input, 5)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("claudit-test-\(UUID().uuidString)/price-table.json")
    }

    func testPriceTableFirstRunSeedsDefaultsAndSaves() {
        let url = tempURL()
        let t = PriceTable.load(from: url, legacy: url.deletingLastPathComponent().appendingPathComponent("none.json"))
        XCTAssertEqual(t, PriceTable.builtIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPriceTableEditsSurviveReload() throws {
        let url = tempURL()
        var t = PriceTable.load(from: url, legacy: url)
        t.prices["claude-sonnet-5-5"]?.input = 9.99
        t.prices["my-model"] = .standard(input: 1, output: 2)
        t.asOf = Date(timeIntervalSince1970: 1_800_000_000)
        try t.save(to: url)
        let reloaded = PriceTable.load(from: url, legacy: url)
        XCTAssertEqual(reloaded.price(for: "claude-sonnet-5-5")?.input, 9.99)
        XCTAssertEqual(reloaded.price(for: "my-model")?.output, 2)
        XCTAssertEqual(reloaded.asOf, t.asOf)
    }

    func testCorruptPriceFileFallsBackWithoutOverwriting() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(PriceTable.load(from: url, legacy: url), PriceTable.builtIn)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testLegacyOverrideFileIsMergedOnce() throws {
        let url = tempURL()
        let legacy = url.deletingLastPathComponent().appendingPathComponent("prices.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["claude-haiku-5-5": ModelPrice.standard(input: 7, output: 8)]).write(to: legacy)
        let t = PriceTable.load(from: url, legacy: legacy)
        XCTAssertEqual(t.price(for: "claude-haiku-5-5")?.input, 7)
        XCTAssertEqual(t.price(for: "claude-sonnet-5-5")?.input, 2)
    }

    func testSlashCommandLabel() {
        let t = SessionFileState.displayText("<command-message>x</command-message><command-name>/loop</command-name><command-args>5m /foo</command-args>")
        XCTAssertEqual(t, "/loop 5m /foo")
        XCTAssertNil(SessionFileState.displayText("[Request interrupted by user]"))
    }
}
