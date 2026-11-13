import Foundation
import ClauditCore

// claudit-report [--days N] [--top N]
var days = 1
var top = 12
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    if a == "--days", let v = args.next(), let n = Int(v) { days = max(1, n) }
    if a == "--top", let v = args.next(), let n = Int(v) { top = max(1, n) }
}

let cal = Calendar.current
let startOfToday = cal.startOfDay(for: Date())
let from = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday)!
let interval = DateInterval(start: from, end: Date().addingTimeInterval(60))

let t0 = Date()
let store = TranscriptStore()
store.refresh(since: from.addingTimeInterval(-86_400))
let parsed = Date()
let (prompts, unpriced) = Aggregator.prompts(from: store.sessions, prices: PriceTable.load())
let report = Report.make(prompts: prompts, interval: interval, unpriced: unpriced)

func pct(_ v: Double, _ of: Double) -> String { of > 0 ? String(format: "%3.0f%%", v / of * 100) : "  -" }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

let t = report.total
print("Claudit — last \(days) day(s): \(Money.format(t.total)) across \(report.prompts.count) prompts (est. at list price)")
print("  carry \(Money.format(t.carry)) (\(pct(t.carry, t.total)))  new input \(Money.format(t.newInput)) (\(pct(t.newInput, t.total)))  output \(Money.format(t.output)) (\(pct(t.output, t.total)))  subagents \(Money.format(t.subagent)) (\(pct(t.subagent, t.total)))")
print("")
print("By activity")
for a in report.byActivity {
    print("  \(pad(a.activity.rawValue, 18)) \(lpad(Money.format(a.cost.total), 8)) \(pct(a.cost.total, t.total))  \(a.count) prompts")
}
print("")
print("Most expensive prompts")
for p in report.prompts.prefix(top) {
    let df = DateFormatter(); df.dateFormat = "MMM d HH:mm"
    print("  \(lpad(Money.format(p.cost.total), 8)) \(pct(p.cost.total, t.total))  \(df.string(from: p.start))  \(pad(p.project, 16)) \(pad(p.activity.rawValue, 17)) \(lpad(String(p.turns), 3)) turns ctx \(lpad(String(p.maxContext / 1000), 4))k  \(p.text.prefix(60))")
}
print("")
print("By project")
for p in report.byProject.prefix(8) { print("  \(pad(p.name, 24)) \(lpad(Money.format(p.cost), 8)) \(pct(p.cost, t.total))") }
print("By model")
for m in report.byModel { print("  \(pad(m.name, 24)) \(lpad(Money.format(m.cost), 8)) \(pct(m.cost, t.total))") }
if !report.insights.isEmpty { print(""); print("Insights"); report.insights.forEach { print("  • \($0)") } }
if !report.unpricedModels.isEmpty { print("\nUnpriced models (add to prices.json): \(report.unpricedModels.joined(separator: ", "))") }
print(String(format: "\nparsed %d files in %.2fs, aggregated in %.2fs", store.sessions.count, parsed.timeIntervalSince(t0), Date().timeIntervalSince(parsed)))
