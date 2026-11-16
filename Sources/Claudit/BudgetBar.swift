import SwiftUI
import ClauditCore

/// Month-to-date spend against the monthly allowance: one tick per day, a marker for today
/// and a marker for the share of the allowance used (red when ahead of the day, green otherwise).
struct BudgetBar: View {
    @ObservedObject var store: UsageStore
    /// Called when the field gains focus, so the host can keep the popover open and give it the keyboard.
    var onBeginEditing: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool

    private var spend: Double { store.month?.total.total ?? 0 }
    private var budget: Budget { Budget(spend: spend, allowance: store.monthlyAllowance, now: Date()) }

    var body: some View {
        let b = budget
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                bar(b)
                    .opacity(b.status == .off ? 0.35 : 1)
                HStack(spacing: 2) {
                    Text("$").foregroundStyle(.secondary)
                    TextField("0", text: $text)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .focused($focused)
                        .focusEffectDisabled()      // drop the system focus ring; the underline is the highlight
                        .padding(.bottom, 2)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(focused ? Color.accentColor : Color.primary.opacity(0.25))
                                .frame(height: 1)
                        }
                        .onSubmit(commit)
                        .onChange(of: text) { _, new in
                            // Save as they type, so closing the popover mid-edit can't lose the value.
                            if let v = Budget.parse(new), v != store.monthlyAllowance { store.monthlyAllowance = v }
                        }
                        .onChange(of: focused) { _, now in
                            if now { onBeginEditing() } else { commit() }
                        }
                }
                .font(.caption)
                .help("Monthly limit")
            }
            .frame(height: 22)
            if b.status != .off {
                Text("\(Money.format(spend)) of $\(store.monthlyAllowance) · day \(b.dayNumber) of \(b.daysInMonth)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = String(store.monthlyAllowance) }
    }

    private func commit() {
        if let v = Budget.parse(text) { store.monthlyAllowance = v }
        text = String(store.monthlyAllowance)
    }

    private func bar(_ b: Budget) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 8).frame(maxHeight: .infinity)
                ForEach(0...b.daysInMonth, id: \.self) { i in
                    Rectangle().fill(Color.primary.opacity(0.35))
                        .frame(width: 1, height: i == 0 || i == b.daysInMonth ? 10 : 5)
                        .offset(x: w * CGFloat(i) / CGFloat(b.daysInMonth) - 0.5)
                        .frame(maxHeight: .infinity)
                }
                marker(.primary, height: h)
                    .offset(x: w * b.dayFraction - 1)
                    .help("Today: day \(b.dayNumber) of \(b.daysInMonth)")
                if b.status != .off {
                    marker(b.status == .over ? .red : .green, height: h)
                        .offset(x: w * b.spendFraction - 1)
                        .help("\(Int((b.spendFraction * 100).rounded()))% of allowance used")
                }
            }
        }
    }

    private func marker(_ c: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 2.5, height: height)
    }
}
