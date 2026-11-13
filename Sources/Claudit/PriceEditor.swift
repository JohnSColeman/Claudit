import SwiftUI
import ClauditCore

/// Editable view of the price table. Changes apply (and are saved to the app's storage) when you press Save.
struct PriceEditorView: View {
    struct Row: Identifiable {
        let id = UUID()
        var model = ""
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var write5m = 0.0
        var write1h = 0.0
        // Higher rates for prompts over `threshold` tokens, when `longOn`.
        var longOn = false
        var threshold = 100_000
        var lInput = 0.0
        var lOutput = 0.0
        var lCacheRead = 0.0
        var lWrite5m = 0.0
        var lWrite1h = 0.0

        init() {}
        init(model: String, price p: ModelPrice) {
            self.model = model
            input = p.input; output = p.output; cacheRead = p.cacheRead
            write5m = p.cacheWrite5m; write1h = p.cacheWrite1h
            if let l = p.longContext {
                longOn = true; threshold = l.threshold
                lInput = l.input; lOutput = l.output; lCacheRead = l.cacheRead
                lWrite5m = l.cacheWrite5m; lWrite1h = l.cacheWrite1h
            }
        }
        var price: ModelPrice {
            ModelPrice(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: write5m, cacheWrite1h: write1h,
                       longContext: longOn ? LongContextPrice(threshold: threshold, input: lInput, output: lOutput,
                                                              cacheRead: lCacheRead, cacheWrite5m: lWrite5m,
                                                              cacheWrite1h: lWrite1h) : nil)
        }
        var allRates: [Double] {
            [input, output, cacheRead, write5m, write1h] + (longOn ? [lInput, lOutput, lCacheRead, lWrite5m, lWrite1h] : [])
        }
        /// Turns long-context pricing on, starting from the standard rates so only the differences need editing.
        mutating func enableLong() {
            longOn = true
            lInput = input; lOutput = output; lCacheRead = cacheRead; lWrite5m = write5m; lWrite1h = write1h
        }
    }

    @ObservedObject var store: UsageStore
    var close: () -> Void

    @State private var rows: [Row]
    @State private var asOf: Date
    @State private var dateTouched = false
    @State private var fetching = false
    @State private var updateStatus: String?
    @State private var proposed: [PriceChange] = []
    @State private var accepted: Set<String> = []
    @State private var showUpdates = false

    init(store: UsageStore, close: @escaping () -> Void) {
        self.store = store
        self.close = close
        _rows = State(initialValue: Self.rows(from: store.priceTable))
        _asOf = State(initialValue: store.priceTable.asOf)
    }

    private static func rows(from table: PriceTable) -> [Row] {
        table.prices.map { Row(model: $0.key, price: $0.value) }
            .sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
    }

    private var problem: String? {
        let ids = rows.map { $0.model.trimmingCharacters(in: .whitespaces) }
        if ids.contains(where: \.isEmpty) { return "Every row needs a model ID." }
        if Set(ids).count != ids.count { return "Model IDs must be unique." }
        if rows.contains(where: { $0.allRates.contains { $0 < 0 } }) {
            return "Prices can't be negative."
        }
        if rows.contains(where: { $0.longOn && $0.threshold <= 0 }) {
            return "A long-prompt threshold must be above zero."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model prices").font(.title3.weight(.semibold))
            Text("US dollars per million tokens. Claudit multiplies each response's tokens by the row whose ID matches the model, or the longest ID that is a prefix of it, so \"claude-opus-5-5\" also covers dated variants. The ↑ button adds a second set of rates for requests whose prompt is over a token threshold, for models that charge more for large prompts.")
                .font(.caption).foregroundStyle(.secondary)

            header
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($rows) { $row in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                TextField("model id", text: $row.model).textFieldStyle(.roundedBorder)
                                number($row.input)
                                number($row.output)
                                number($row.cacheRead)
                                number($row.write5m)
                                number($row.write1h)
                                Button {
                                    if row.longOn { row.longOn = false } else { row.enableLong() }
                                } label: { Image(systemName: row.longOn ? "arrow.up.circle.fill" : "arrow.up.circle") }
                                    .buttonStyle(.plain).foregroundStyle(row.longOn ? Color.accentColor : .secondary)
                                    .help("Higher rates for large prompts")
                                Button {
                                    rows.removeAll { $0.id == row.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Remove this model")
                            }
                            if row.longOn {
                                HStack(spacing: 6) {
                                    HStack(spacing: 4) {
                                        Spacer()
                                        Text("Prompts over").foregroundStyle(.secondary)
                                        TextField("100000", value: $row.threshold, format: .number.grouping(.never))
                                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 82)
                                        Text("tokens:").foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                    number($row.lInput)
                                    number($row.lOutput)
                                    number($row.lCacheRead)
                                    number($row.lWrite5m)
                                    number($row.lWrite1h)
                                    Color.clear.frame(width: 16 + 6 + 16, height: 1)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                Button { rows.append(Row()) } label: { Label("Add model", systemImage: "plus") }
                Button("Reset to defaults") {
                    rows = Self.rows(from: .builtIn)
                    asOf = PriceTable.seedDate
                    dateTouched = true
                }
                Button { fetchUpdates() } label: {
                    if fetching { ProgressView().controlSize(.small) } else { Text("Update from Anthropic…") }
                }
                .disabled(fetching)
                .help("Reads Anthropic's pricing page and shows what differs from this table")
                Spacer()
                DatePicker("Prices as of", selection: $asOf, displayedComponents: .date)
                    .fixedSize()
                    .onChange(of: asOf) { _, _ in dateTouched = true }
            }

            Text("Cache reads are usually 0.1× the input price, 5-minute cache writes 1.25× and 1-hour writes 2×. Only some models' cache prices have been confirmed, so check the others against Anthropic's pricing page. Saving re-prices your whole history, because Claudit applies one price per model.")
                .font(.caption2).foregroundStyle(.secondary)

            Link("Check current pay-as-you-go API prices on Anthropic's site ↗",
                 destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
                .font(.caption)

            HStack {
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                else if let updateStatus { Text(updateStatus).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 780, height: 560)
        .sheet(isPresented: $showUpdates) {
            PriceUpdateSheet(changes: proposed, accepted: $accepted) {
                applyUpdates()
                showUpdates = false
            } cancel: {
                showUpdates = false
            }
        }
    }

    // MARK: Update from Anthropic

    /// Fetches Anthropic's pricing page and compares it with the rows as currently edited. Nothing changes
    /// until the user accepts, and even then it only edits the table here: Save still decides what is kept.
    private func fetchUpdates() {
        fetching = true
        updateStatus = nil
        Task {
            defer { fetching = false }
            var request = URLRequest(url: PriceImport.pageURL)
            request.setValue("text/markdown", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else {
                    updateStatus = "Anthropic's site gave an unexpected response."
                    return
                }
                let parsed = PriceImport.parse(markdown: text)
                guard !parsed.prices.isEmpty else {
                    updateStatus = "Couldn't find the price table on the page. Its layout may have changed."
                    return
                }
                var current: [String: ModelPrice] = [:]
                for r in rows { current[r.model.trimmingCharacters(in: .whitespaces)] = r.price }
                let changes = PriceImport.changes(from: parsed.prices, against: current)
                let skipped = parsed.skipped.isEmpty ? "" : " \(parsed.skipped.count) page rows couldn't be read."
                if changes.isEmpty {
                    updateStatus = "Already matches Anthropic's page (\(parsed.prices.count) models checked)." + skipped
                    return
                }
                proposed = changes
                accepted = Set(changes.map(\.model))
                updateStatus = skipped.isEmpty ? nil : skipped
                showUpdates = true
            } catch {
                updateStatus = "Couldn't reach Anthropic's site: \(error.localizedDescription)"
            }
        }
    }

    private func applyUpdates() {
        let chosen = proposed.filter { accepted.contains($0.model) }
        for c in chosen {
            let row = Row(model: c.model, price: c.new)
            if let i = rows.firstIndex(where: { $0.model.trimmingCharacters(in: .whitespaces) == c.model }) {
                rows[i] = row
            } else {
                rows.append(row)
            }
        }
        rows.sort { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
        if !chosen.isEmpty {
            asOf = Date()
            dateTouched = true
            updateStatus = "Applied \(chosen.count) change\(chosen.count == 1 ? "" : "s"). Press Save to keep them."
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Model ID").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Input", "Output", "Cache read", "Write 5m", "Write 1h"], id: \.self) {
                Text($0).frame(width: 82, alignment: .trailing)
            }
            Color.clear.frame(width: 16 + 6 + 16, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func number(_ value: Binding<Double>) -> some View {
        TextField("0", value: value, format: .number.precision(.fractionLength(0...4)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 82)
    }

    private func save() {
        var prices: [String: ModelPrice] = [:]
        for r in rows { prices[r.model.trimmingCharacters(in: .whitespaces)] = r.price }
        let changed = prices != store.priceTable.prices
        // Keep the date the user picked; otherwise stamp edits with today.
        let date = dateTouched ? asOf : (changed ? Date() : store.priceTable.asOf)
        store.setPrices(PriceTable(prices: prices, asOf: date))
        close()
    }
}

/// Lists what Anthropic's page changes in the table, with a checkbox per model.
struct PriceUpdateSheet: View {
    let changes: [PriceChange]
    @Binding var accepted: Set<String>
    var apply: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prices that differ from Anthropic's page").font(.title3.weight(.semibold))
            Text("Tick the models to update. Nothing is saved until you press Save in the price editor.")
                .font(.caption).foregroundStyle(.secondary)
            List(changes) { c in
                Toggle(isOn: Binding(
                    get: { accepted.contains(c.model) },
                    set: { on in if on { accepted.insert(c.model) } else { accepted.remove(c.model) } })) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.model).font(.body.monospaced())
                        Text(c.summary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            HStack {
                Button("Select all") { accepted = Set(changes.map(\.model)) }
                Button("Select none") { accepted = [] }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply \(accepted.count)", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(accepted.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}
