import SwiftUI
import ClauditCore

enum Palette {
    static let carry = Color.indigo
    static let newInput = Color.orange
    static let output = Color.teal
    static let subagent = Color.pink
}

/// Stacked bar of the four cost components, scaled so `scale` fills the full width.
struct CostBar: View {
    let cost: CostBreakdown
    let scale: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let k = scale > 0 ? w / scale : 0
            HStack(spacing: 0) {
                Rectangle().fill(Palette.newInput).frame(width: cost.newInput * k)
                Rectangle().fill(Palette.carry).frame(width: cost.carry * k)
                Rectangle().fill(Palette.output).frame(width: cost.output * k)
                Rectangle().fill(Palette.subagent).frame(width: cost.subagent * k)
                Spacer(minLength: 0)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .frame(height: height)
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            dot(Palette.newInput, "new context")
            dot(Palette.carry, "context carry")
            dot(Palette.output, "output")
            dot(Palette.subagent, "subagents")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    var onHover: (Bool) -> Void
    var onEditPrices: () -> Void = {}
    /// Snapshot rendering can't draw ScrollView or segmented Pickers, so dev snapshots use plain stand-ins.
    var flat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            Divider()
            if let error = store.scanError {
                scanErrorBanner(error)
            }
            if store.today == nil {
                Spacer()
                HStack { Spacer(); ProgressView("Reading transcripts…"); Spacer() }
                Spacer()
            } else if store.tab == .usage {
                usageTab
            } else {
                projectsTab
            }
            footer
        }
        .padding(14)
        .frame(width: 410, height: 580)
        .onHover(perform: onHover)
    }

    private func scanErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't read transcripts").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if flat { VStack(alignment: .leading) { content(); Spacer(minLength: 0) } }
        else { ScrollView { content() } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if flat {
                Text(store.tab.rawValue).font(.callout.weight(.semibold))
                Spacer()
                Text(store.period.title).font(.callout)
            } else {
                Picker("", selection: $store.tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Spacer()
                Picker("", selection: $store.period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
        }
    }

    // MARK: Usage tab

    @ViewBuilder
    private var usageTab: some View {
        if let report = store.current {
            summary(report)
            Divider()
            scrollable {
                VStack(alignment: .leading, spacing: 16) {
                    if report.prompts.isEmpty {
                        Text(store.selectedCount == 0 ? "No projects selected. Pick some on the Projects tab."
                                                      : "No prompts in this period.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !report.insights.isEmpty { insights(report) }
                    prompts(report)
                    activities(report)
                    projectsAndModels(report)
                    if !report.unpricedModels.isEmpty {
                        Text("No price for: \(report.unpricedModels.joined(separator: ", ")). Use Edit prices to add it.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.trailing, 6)
            }
        }
    }

    private func summary(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.format(r.total.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("est. at API list price").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(r.prompts.count) prompts").font(.caption).foregroundStyle(.secondary)
            }
            CostBar(cost: r.total, scale: r.total.total, height: 8)
            Legend()
            if store.isFiltered {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.blue)
                    Text("\(store.selectedCount) of \(store.universe.count) projects")
                    Spacer()
                    Button("Show all") { store.showAll() }.buttonStyle(.link)
                }
                .font(.caption)
            }
            if let live = store.live, Calendar.current.isDateInToday(live.end),
               Date().timeIntervalSince(live.end) < 600 {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    Text("Latest: \(Money.format(live.cost.total)) · \(live.activity.rawValue.lowercased()) · \(live.text)")
                        .lineLimit(1)
                }
                .font(.caption)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                if live.maxContext >= 150_000 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Context is \(live.maxContext / 1000)k tokens, so every turn re-reads it. /clear or /compact before the next task.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Projects tab

    private var projectsTab: some View {
        let rows = store.projectRows
        let maxCost = rows.map(\.cost.total).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filter by project").font(.callout.weight(.semibold))
                Spacer()
                Text("\(store.selectedCount) of \(store.universe.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Button("All") { store.showAll() }.buttonStyle(.link).font(.caption)
                Button("None") { store.hideAll() }.buttonStyle(.link).font(.caption)
            }
            Text("Unticked projects are left out of the Usage tab and the menu bar total. Costs below are for \(store.period == .month ? store.period.title : store.period.title.lowercased()).")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            scrollable {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ProjectFilterRow(row: row, maxCost: maxCost,
                                         toggle: { store.toggle(row.name) },
                                         only: { store.only(row.name) })
                    }
                }
                .padding(.trailing, 6)
            }
        }
    }

    // MARK: Sections

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func insights(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("What's driving it")
            ForEach(r.insights, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb").font(.caption).foregroundStyle(.yellow)
                    Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func prompts(_ r: Report) -> some View {
        let top = Array(r.prompts.prefix(10))
        let maxCost = top.first?.cost.total ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Most expensive prompts")
            ForEach(top) { p in
                PromptRow(prompt: p, maxCost: maxCost, total: r.total.total)
            }
            if r.prompts.count > top.count {
                Text("+ \(r.prompts.count - top.count) cheaper prompts")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func activities(_ r: Report) -> some View {
        let maxCost = r.byActivity.first?.cost.total ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("By activity")
            ForEach(r.byActivity) { a in
                VStack(spacing: 3) {
                    HStack {
                        Image(systemName: a.activity.symbol).frame(width: 16).foregroundStyle(.secondary)
                        Text(a.activity.rawValue).font(.callout)
                        Text("\(a.count)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(percent(a.cost.total, r.total.total)).font(.caption).foregroundStyle(.secondary)
                        Text(Money.format(a.cost.total)).font(.callout).monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                    CostBar(cost: a.cost, scale: maxCost)
                }
            }
        }
    }

    private func projectsAndModels(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("By project")
            ForEach(r.byProject.prefix(5)) { p in nameRow(p.name, p.cost, r.total.total) }
            sectionTitle("By model").padding(.top, 4)
            ForEach(r.byModel.prefix(5)) { m in nameRow(m.name, m.cost, r.total.total) }
        }
    }

    private func nameRow(_ name: String, _ cost: Double, _ total: Double) -> some View {
        HStack {
            Text(name).font(.callout).lineLimit(1)
            Spacer()
            Text(percent(cost, total)).font(.caption).foregroundStyle(.secondary)
            Text(Money.format(cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button("Edit prices", action: onEditPrices).buttonStyle(.link).font(.caption2)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var footerText: String {
        let asOf = store.priceTable.asOf.formatted(.dateTime.day().month(.abbreviated).year())
        var parts: [String] = []
        if let g = store.current?.generated { parts.append("Updated \(g.formatted(date: .omitted, time: .shortened))") }
        parts.append("Prices as of \(asOf)")
        return parts.joined(separator: " · ")
    }
}

func percent(_ v: Double, _ of: Double) -> String {
    of > 0 ? "\(Int((v / of * 100).rounded()))%" : "–"
}

struct PromptRow: View {
    let prompt: PromptCost
    let maxCost: Double
    let total: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: prompt.activity.symbol).frame(width: 16).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.text).font(.callout).lineLimit(1)
                    Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Money.format(prompt.cost.total)).font(.callout.weight(.medium)).monospacedDigit()
                    Text(percent(prompt.cost.total, total)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            CostBar(cost: prompt.cost, scale: maxCost)
        }
        .help(tooltip)
    }

    private var meta: String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(prompt.start) ? "h:mm a" : "EEE h:mm a"
        var s = "\(f.string(from: prompt.start)) · \(prompt.project) · \(prompt.turns) \(prompt.turns == 1 ? "turn" : "turns")"
        if prompt.maxContext > 0 { s += " · \(prompt.maxContext / 1000)k" }
        return s
    }

    private var tooltip: String {
        let c = prompt.cost
        var lines = [prompt.text, "",
                     "New context  \(Money.format(c.newInput))",
                     "Context carry \(Money.format(c.carry))",
                     "Output       \(Money.format(c.output))"]
        if c.subagent > 0 { lines.append("Subagents    \(Money.format(c.subagent)) (\(prompt.subagentTurns) turns)") }
        let tools = prompt.toolCounts.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        if !tools.isEmpty { lines.append("Tools: \(tools)") }
        return lines.joined(separator: "\n")
    }
}

struct ProjectFilterRow: View {
    let row: ProjectRow
    let maxCost: Double
    let toggle: () -> Void
    let only: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: row.included ? "checkmark.square.fill" : "square")
                            .foregroundStyle(row.included ? Color.accentColor : Color.secondary)
                            .font(.body)
                        Text(row.name).font(.callout).lineLimit(1)
                            .foregroundStyle(row.included ? Color.primary : Color.secondary)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("only", action: only).buttonStyle(.link).font(.caption)
                Text(Money.format(row.cost.total)).font(.callout).monospacedDigit()
                    .foregroundStyle(row.included ? Color.primary : Color.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            CostBar(cost: row.cost, scale: maxCost)
                .opacity(row.included ? 1 : 0.35)
        }
    }
}
