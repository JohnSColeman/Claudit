import Foundation
import Combine
import ClauditCore

enum Period: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }

    /// Label for the picker. The month is spelled out in full, e.g. "November".
    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return Date().formatted(.dateTime.month(.wide))
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case projects = "Projects"
    var id: String { rawValue }
}

struct ProjectRow: Identifiable {
    var id: String { name }
    let name: String
    let cost: CostBreakdown
    let included: Bool
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var today: Report?
    @Published var week: Report?
    @Published var month: Report?
    @Published var live: PromptCost?
    @Published var period: Period = .today
    @Published var tab: Tab = .usage
    @Published var isLoading = true
    /// Set when the transcript scan failed or was blocked, so the popover can say why it is empty.
    @Published private(set) var scanError: String?
    /// The editable price table, loaded from (and saved to) the app's own storage.
    @Published private(set) var priceTable: PriceTable

    /// Projects the user has switched off. Everything is included by default, and new projects
    /// start included because the filter stores exclusions, not selections.
    @Published private(set) var excluded: Set<String>
    /// Every project seen since the start of the scan window (the current month or the last 7 days, whichever is longer).
    @Published private(set) var universe: [String] = []
    @Published private(set) var todayCosts: [String: CostBreakdown] = [:]
    @Published private(set) var weekCosts: [String: CostBreakdown] = [:]
    @Published private(set) var monthCosts: [String: CostBreakdown] = [:]
    /// Monthly spend target in whole dollars. Zero means no target, and the budget bar is greyed out.
    @Published var monthlyAllowance: Int = 0 {
        didSet { if persist { UserDefaults.standard.set(monthlyAllowance, forKey: Self.allowanceKey) } }
    }

    private let queue = DispatchQueue(label: "claudit.scan", qos: .utility)
    private let transcripts = TranscriptStore()
    private var pendingReprice = false
    private var timer: Timer?
    private var started = false
    private var lastDay = Calendar.current.startOfDay(for: Date())
    private var allPrompts: [PromptCost] = []
    private var unpriced: Set<String> = []
    private let persist: Bool
    private static let defaultsKey = "excludedProjects"
    private static let allowanceKey = "monthlyAllowance"

    init() {
        let env = ProcessInfo.processInfo.environment
        persist = env["CLAUDIT_SNAPSHOT"] == nil     // snapshot runs must not touch real preferences
        priceTable = PriceTable.load()
        if persist {
            excluded = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
            monthlyAllowance = UserDefaults.standard.integer(forKey: Self.allowanceKey)
        } else {
            excluded = Set((env["CLAUDIT_EXCLUDE"] ?? "").split(separator: ",").map(String.init))
            if env["CLAUDIT_TAB"] == "projects" { tab = .projects }
            if let raw = env["CLAUDIT_PERIOD"], let p = Period(rawValue: raw) { period = p }
            monthlyAllowance = Int(env["CLAUDIT_ALLOWANCE"] ?? "") ?? 0
        }
    }

    var current: Report? {
        switch period {
        case .today: return today
        case .week: return week
        case .month: return month
        }
    }

    /// The scan window starts at the earlier of "7 days ago" and "the first of this month".
    private static func windowStarts(now: Date = Date()) -> (today: Date, week: Date, month: Date, scan: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let week = cal.date(byAdding: .day, value: -6, to: today)!
        let month = cal.dateInterval(of: .month, for: now)?.start ?? today
        return (today, week, month, min(week, month))
    }

    var isFiltered: Bool { universe.contains(where: excluded.contains) }
    var selectedCount: Int { universe.filter { !excluded.contains($0) }.count }

    /// Rows for the Projects tab: every known project, costliest first for the chosen period.
    var projectRows: [ProjectRow] {
        let costs: [String: CostBreakdown]
        switch period {
        case .today: costs = todayCosts
        case .week: costs = weekCosts
        case .month: costs = monthCosts
        }
        return universe
            .map { ProjectRow(name: $0, cost: costs[$0] ?? CostBreakdown(), included: !excluded.contains($0)) }
            .sorted { a, b in
                a.cost.total != b.cost.total ? a.cost.total > b.cost.total
                    : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    // MARK: Filter actions

    func toggle(_ project: String) {
        if excluded.contains(project) { excluded.remove(project) } else { excluded.insert(project) }
        filterChanged()
    }

    func showAll() {
        excluded = []
        filterChanged()
    }

    func hideAll() {
        excluded = Set(universe)
        filterChanged()
    }

    func only(_ project: String) {
        excluded = Set(universe.filter { $0 != project })
        filterChanged()
    }

    private func filterChanged() {
        if persist { UserDefaults.standard.set(Array(excluded).sorted(), forKey: Self.defaultsKey) }
        rebuild()
    }

    // MARK: Prices

    /// Applies edited prices: saves them and re-prices all cached history.
    func setPrices(_ table: PriceTable) {
        priceTable = table
        if persist {
            do { try table.save() } catch { NSLog("Claudit: could not save prices: \(error)") }
        }
        pendingReprice = true
        refresh()
    }

    // MARK: Refresh

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let first = (today == nil)
        let day = Calendar.current.startOfDay(for: Date())
        let rolledOver = day != lastDay
        lastDay = day
        let scanStart = Self.windowStarts().scan
        let prices = priceTable
        let reprice = pendingReprice
        pendingReprice = false
        queue.async { [transcripts] in
            let changed = transcripts.refresh(since: scanStart.addingTimeInterval(-86_400))
            let error = transcripts.lastError
            DispatchQueue.main.async { self.scanError = error }
            guard changed || first || rolledOver || reprice else { return }

            let (prompts, unpriced) = Aggregator.prompts(from: transcripts.sessions, prices: prices)
            DispatchQueue.main.async {
                self.allPrompts = prompts
                self.unpriced = unpriced
                self.isLoading = false
                self.rebuild()
            }
        }
    }

    /// Rebuilds reports from the cached prompts. Cheap (no file reads), so filter changes apply instantly.
    private func rebuild() {
        let w = Self.windowStarts()
        let end = Date().addingTimeInterval(3600)
        let todayInterval = DateInterval(start: w.today, end: end)
        let weekInterval = DateInterval(start: w.week, end: end)
        let monthInterval = DateInterval(start: w.month, end: end)
        let scanInterval = DateInterval(start: w.scan, end: end)

        // Unfiltered per-project totals feed the Projects tab, so unticked projects still show their cost.
        func costs(in interval: DateInterval) -> [String: CostBreakdown] {
            var out: [String: CostBreakdown] = [:]
            for p in allPrompts where interval.contains(p.start) {
                var c = out[p.project] ?? CostBreakdown()
                c.carry += p.cost.carry
                c.newInput += p.cost.newInput
                c.output += p.cost.output
                c.subagent += p.cost.subagent
                out[p.project] = c
            }
            return out
        }
        todayCosts = costs(in: todayInterval)
        weekCosts = costs(in: weekInterval)
        monthCosts = costs(in: monthInterval)
        universe = costs(in: scanInterval).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let filtered = allPrompts.filter { !excluded.contains($0.project) }
        today = Report.make(prompts: filtered, interval: todayInterval, unpriced: unpriced)
        week = Report.make(prompts: filtered, interval: weekInterval, unpriced: unpriced)
        month = Report.make(prompts: filtered, interval: monthInterval, unpriced: unpriced)
        live = filtered.max { $0.end < $1.end }
    }
}
