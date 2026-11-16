import XCTest
@testable import ClauditCore

final class BudgetTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func budget(spend: Double = 0, allowance: Int, at s: String) -> Budget {
        Budget(spend: spend, allowance: allowance, now: date(s), calendar: cal)
    }

    func testDayFractionMidMonth() {
        let b = budget(allowance: 100, at: "2026-11-16T12:00:00Z")
        XCTAssertEqual(b.daysInMonth, 30)
        XCTAssertEqual(b.dayFraction, 15.5 / 30, accuracy: 1e-9)
    }

    func testDayFractionBounds() {
        XCTAssertEqual(budget(allowance: 1, at: "2026-11-01T00:00:00Z").dayFraction, 0)
        let end = budget(allowance: 1, at: "2026-11-30T23:59:59Z").dayFraction
        XCTAssertLessThan(end, 1)
        XCTAssertGreaterThan(end, 0.99)
    }

    func testDaysInMonth() {
        XCTAssertEqual(budget(allowance: 1, at: "2026-02-10T00:00:00Z").daysInMonth, 28)
        XCTAssertEqual(budget(allowance: 1, at: "2026-12-10T00:00:00Z").daysInMonth, 31)
    }

    func testOffWhenAllowanceZero() {
        let b = budget(spend: 50, allowance: 0, at: "2026-11-16T12:00:00Z")
        XCTAssertEqual(b.status, .off)
        XCTAssertEqual(b.spendFraction, 0)
    }

    func testUnderIsGreen() {
        let b = budget(spend: 10, allowance: 100, at: "2026-11-16T12:00:00Z")
        XCTAssertEqual(b.status, .under)
        XCTAssertEqual(b.spendFraction, 0.1, accuracy: 1e-9)
    }

    func testOverIsRed() {
        XCTAssertEqual(budget(spend: 90, allowance: 100, at: "2026-11-16T12:00:00Z").status, .over)
    }

    func testTieIsUnder() {
        let day = budget(allowance: 100, at: "2026-11-16T12:00:00Z").dayFraction
        XCTAssertEqual(budget(spend: day * 100, allowance: 100, at: "2026-11-16T12:00:00Z").status, .under)
    }

    func testClampsAtOne() {
        let b = budget(spend: 500, allowance: 10, at: "2026-11-16T12:00:00Z")
        XCTAssertEqual(b.spendFraction, 1)
        XCTAssertEqual(b.status, .over)
    }

    func testParse() {
        XCTAssertEqual(Budget.parse("150"), 150)
        XCTAssertEqual(Budget.parse("0"), 0)
        XCTAssertEqual(Budget.parse(" 20 "), 20)
        for bad in ["", "-5", "1.5", "abc", "+3"] { XCTAssertNil(Budget.parse(bad), bad) }
    }
}
