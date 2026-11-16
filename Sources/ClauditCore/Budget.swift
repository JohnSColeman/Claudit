import Foundation

/// Month-to-date spend against a monthly allowance, as positions along a month-long bar.
public struct Budget: Equatable {
    public enum Status { case off, under, over }

    public let daysInMonth: Int
    /// The day of the month, 1-based.
    public let dayNumber: Int
    /// How far through the month `now` is, 0...1.
    public let dayFraction: Double
    /// Share of the allowance spent, clamped to 0...1. Zero when the budget is off.
    public let spendFraction: Double
    public let status: Status

    public init(spend: Double, allowance: Int, now: Date, calendar: Calendar = .current) {
        daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        dayNumber = calendar.component(.day, from: now)
        // Built from calendar days so a 23- or 25-hour day (clock change) doesn't shift the marker.
        let startOfDay = calendar.startOfDay(for: now)
        let dayLength = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.timeIntervalSince(startOfDay)
        let intoDay = min(max(now.timeIntervalSince(startOfDay) / dayLength, 0), 1)
        dayFraction = min(max((Double(dayNumber - 1) + intoDay) / Double(daysInMonth), 0), 1)
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
