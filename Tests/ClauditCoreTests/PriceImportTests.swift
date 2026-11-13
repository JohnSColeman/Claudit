import XCTest
@testable import ClauditCore

final class PriceImportTests: XCTestCase {
    private let page = """
    ---
    title: Pricing
    ---

    ## Model pricing

    | Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
    | :---- | :---------------- | :-------------- | :-------------- | :----------------------- | :------------ |
    | Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok<sup>1</sup> | $50 / MTok |
    | Claude Opus 4.1 ([retired, except on Bedrock](https://example.com/deprecations)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |
    | Claude Sonnet 5 | $2 / MTok<sup>3</sup> | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok<sup>3</sup> |
    | Claude Haiku 5.5 (for prompts up to 100,000 tokens) | $0.10 / MTok | $0.125 / MTok | $0.20 / MTok | $0.01 / MTok | $0.50 / MTok |
    | Claude Haiku 5.5 (for prompts over 100,000 tokens) | $0.50 / MTok | $0.625 / MTok | $1 / MTok | $0.05 / MTok | $2.50 / MTok |
    | Something else entirely | $1 / MTok | $1 / MTok | $1 / MTok | $1 / MTok | $1 / MTok |
    | Claude Opus 9 | Contact sales | | | | |

    *<sup>1 A footnote</sup>*

    ## Batch processing

    | Model | Batch input | Batch output |
    | :---- | :---------- | :----------- |
    | Claude Opus 5.5 | $2 / MTok | $10 / MTok |
    """

    func testParsesRowsTiersAndFootnotes() throws {
        let r = PriceImport.parse(markdown: page)
        XCTAssertEqual(Set(r.prices.keys), ["claude-fable-5-1", "claude-opus-4-1", "claude-sonnet-5", "claude-haiku-5-5"])
        let fable = try XCTUnwrap(r.prices["claude-fable-5-1"])
        XCTAssertEqual(fable.cacheRead, 0.25, accuracy: 1e-12)
        XCTAssertEqual(fable.cacheWrite5m, 12.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.prices["claude-opus-4-1"]).output, 75, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.prices["claude-sonnet-5"]).input, 2, accuracy: 1e-12)

        let haiku = try XCTUnwrap(r.prices["claude-haiku-5-5"])
        XCTAssertEqual(haiku.input, 0.10, accuracy: 1e-12)
        let long = try XCTUnwrap(haiku.longContext)
        XCTAssertEqual(long.threshold, 100_000)
        XCTAssertEqual(long.output, 2.5, accuracy: 1e-12)
        XCTAssertEqual(long.cacheRead, 0.05, accuracy: 1e-12)

        // Unmappable or incomplete rows are reported, and the batch table below is not read.
        XCTAssertEqual(Set(r.skipped), ["Something else entirely", "Claude Opus 9"])
        XCTAssertNil(r.prices["claude-opus-5-5"])
    }

    func testChangesIgnoreFloatingPointNoiseAndReportRealDifferences() {
        var table = PriceTable.builtIn.prices
        table["claude-fable-5-1"]!.cacheRead = 1            // the old, wrong value
        table["claude-haiku-5-5"]!.cacheRead = 0.010000000000000002   // as saved by the editor
        let parsed = PriceImport.parse(markdown: page).prices
        let changes = PriceImport.changes(from: parsed, against: table)

        XCTAssertEqual(changes.map(\.model), ["claude-fable-5-1"])
        XCTAssertEqual(changes[0].summary, "cache read 1 → 0.25")

        table["claude-haiku-5-5"]!.longContext = nil
        table["claude-opus-4-1"] = nil
        let more = PriceImport.changes(from: parsed, against: table)
        XCTAssertEqual(more.map(\.model), ["claude-fable-5-1", "claude-haiku-5-5", "claude-opus-4-1"])
        XCTAssertTrue(more[1].summary.contains("adds rates for prompts over 100000 tokens"))
        XCTAssertTrue(more[2].isNew)
    }

    func testBuiltInTableMatchesPageFormat() {
        let r = PriceImport.parse(markdown: page)
        // Built-in defaults were taken from the same page, so these rows must already agree.
        XCTAssertEqual(PriceImport.changes(from: r.prices, against: PriceTable.builtIn.prices), [])
    }
}
