import Foundation

/// Month-to-date spend against a monthly allowance, as positions along a month-long bar.
public struct Budget: Equatable {
    public enum Status { case off, under, over }

    public let daysInMonth: Int
    /// How far through the month `now` is, 0...1.
    public let dayFraction: Double
    /// Share of the allowance spent, clamped to 0...1. Zero when the budget is off.
    public let spendFraction: Double
    public let status: Status

    public init(spend: Double, allowance: Int, now: Date, calendar: Calendar = .current) {
        let month = calendar.dateInterval(of: .month, for: now)!
        daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        dayFraction = min(max(now.timeIntervalSince(month.start) / month.duration, 0), 1)
        if allowance > 0 {
            let raw = max(spend, 0) / Double(allowance)
            spendFraction = min(raw, 1)
            status = raw > dayFraction ? .over : .under
        } else {
            spendFraction = 0
            status = .off
        }
    }

    /// A non-negative whole number of dollars, or nil for anything else.
    public static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(t)
    }
}
