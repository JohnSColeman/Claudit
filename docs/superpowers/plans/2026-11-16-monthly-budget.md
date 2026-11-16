# Monthly Budget Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show month-to-date spend against a user-set monthly allowance as a tick bar with day and spend markers, above the popover footer.

**Architecture:** Pure marker maths in `ClauditCore` (`Budget`), an allowance property on `UsageStore` persisted in `UserDefaults`, and a thin `BudgetBar` SwiftUI view inserted in `UsagePopover` between the content and `footer`.

**Tech Stack:** Swift 6 tools (language mode v5), SwiftUI, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-16-monthly-budget-design.md`

## Global Constraints

- Allowance is a non-negative whole number of dollars; `0` means "off" (default).
- Spend = `store.month?.total.total` (project-filtered).
- Spend marker red when `spendFraction > dayFraction`, green otherwise (tie = green).
- Persist under `UserDefaults` key `monthlyAllowance`; do not persist when `CLAUDIT_SNAPSHOT` is set.
- Widget sits between the content area and `footer`, on both tabs.

## Review Focus

- Allowance 0 → greyed chart, no spend marker, field still editable.
- Spend far above allowance → marker clamps to the bar end, stays red.
- Non-numeric / negative / empty field input → rejected, previous value kept.
- First instant of the month and last instant of the month → day marker at 0 and 1, within bounds.
- 28-, 30-, 31-day months → correct tick count.

---

### Task 1: Budget maths in ClauditCore

**Files:**
- Create: `Sources/ClauditCore/Budget.swift`
- Test: `Tests/ClauditCoreTests/BudgetTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Budget: Equatable {
      public enum Status { case off, under, over }
      public let daysInMonth: Int
      public let dayFraction: Double      // 0...1
      public let spendFraction: Double    // 0...1 (clamped); 0 when off
      public let status: Status
      public init(spend: Double, allowance: Int, now: Date, calendar: Calendar = .current)
      public static func parse(_ text: String) -> Int?   // non-negative whole number or nil
  }
  ```

- [ ] **Step 1: Write failing tests** in `BudgetTests.swift` using a fixed UTC Gregorian calendar:
  - `testDayFractionMidMonth`: 2026-11-16 12:00 → `daysInMonth == 30`, `dayFraction ≈ (15 + 0.5)/30`.
  - `testDayFractionBounds`: 2026-11-01 00:00 → `0`; 2026-11-30 23:59:59 → `< 1` and `> 0.99`.
  - `testDaysInMonth`: Feb 2026 → 28, Dec 2026 → 31.
  - `testOffWhenAllowanceZero`: allowance 0, spend 50 → `status == .off`, `spendFraction == 0`.
  - `testUnderIsGreen`: allowance 100, spend 10, mid-month → `.under`, `spendFraction == 0.1`.
  - `testOverIsRed`: allowance 100, spend 90, day fraction ≈ 0.52 → `.over`.
  - `testTieIsUnder`: choose spend/allowance exactly equal to `dayFraction` → `.under`.
  - `testClampsAtOne`: allowance 10, spend 500 → `spendFraction == 1`, `.over`.
  - `testParse`: `"150"`→150, `"0"`→0, `" 20 "`→20, `""`/`"-5"`/`"1.5"`/`"abc"`→nil.

- [ ] **Step 2: Run** `swift test --filter BudgetTests` — expected: FAIL (`Budget` undefined).

- [ ] **Step 3: Implement `Budget`** in `Sources/ClauditCore/Budget.swift` per the Interfaces block. Day fraction = `(now − startOfMonth) / (endOfMonth − startOfMonth)` from `calendar.dateInterval(of: .month, for:)`, clamped to 0...1. `parse` trims whitespace and requires all-digit input (`Int(text)` on digits-only string).

- [ ] **Step 4: Run** `swift test --filter BudgetTests` — expected: PASS.

- [ ] **Step 5: Commit** `git add Sources/ClauditCore/Budget.swift Tests/ClauditCoreTests/BudgetTests.swift && git commit -m "Add Budget marker maths"`

### Task 2: Store property and persistence

**Files:**
- Modify: `Sources/Claudit/UsageStore.swift` (new `@Published var monthlyAllowance: Int`, loaded in `init`, saved on change, new `private static let allowanceKey = "monthlyAllowance"`)

**Interfaces:**
- Consumes: `Budget.parse` is used by the view, not the store.
- Produces: `@Published var monthlyAllowance: Int` (default 0), with `didSet` that writes to `UserDefaults` only when `persist` is true.

- [ ] **Step 1: Add the property** following the `excluded` pattern: read `UserDefaults.standard.integer(forKey:)` in the `persist` branch of `init`; in snapshot mode read optional env `CLAUDIT_ALLOWANCE` so screenshots can show the widget.

- [ ] **Step 2: Build** `swift build` — expected: success.

- [ ] **Step 3: Commit** `git add Sources/Claudit/UsageStore.swift && git commit -m "Persist monthly allowance in the store"`

### Task 3: BudgetBar view and popover wiring

**Files:**
- Create: `Sources/Claudit/BudgetBar.swift`
- Modify: `Sources/Claudit/PopoverView.swift:76` (insert `BudgetBar(store: store)` immediately before `footer`, inside the VStack, so it shows on both tabs)

**Interfaces:**
- Consumes: `Budget(spend:allowance:now:)`, `Budget.parse`, `store.monthlyAllowance`, `store.month?.total.total`.
- Produces: `struct BudgetBar: View { @ObservedObject var store: UsageStore }`.

- [ ] **Step 1: Implement `BudgetBar`**: a `HStack` with a `GeometryReader` bar (capsule track like `CostBar`, one minor tick per day at `i/daysInMonth`, a day marker line in `.primary`, and a spend marker line coloured `.red` for `.over` / `.green` for `.under`) and, on the right, a `$`-prefixed `TextField` (~60pt wide) bound to a local string. On commit/blur, `Budget.parse` the text; on success set `store.monthlyAllowance`, otherwise reset the text to the current value. When `status == .off`, apply `.opacity(0.35)` and omit the spend marker on the bar only (not the field). Add a short caption below, e.g. `"$X of $Y · day D of N"`, hidden when off. Add `.help` tooltips on the markers.

- [ ] **Step 2: Wire into `UsagePopover`** before `footer`, with a `Divider()` above if the existing layout needs separation.

- [ ] **Step 3: Verify visually**: `swift build`, then run the app per the project's snapshot mode (`CLAUDIT_SNAPSHOT=<path> CLAUDIT_ALLOWANCE=0`, then `=300`, `=1`) and check: greyed at 0, green/red markers at the other values, field editable in all cases. Flat snapshot mode can't render some controls; if `TextField` fails in `flat`, use a plain `Text` stand-in in that mode as `PopoverView` already does for Picker.

- [ ] **Step 4: Run full tests** `swift test` — expected: all pass.

- [ ] **Step 5: Commit** `git add Sources/Claudit && git commit -m "Add monthly budget bar to the popover"`
