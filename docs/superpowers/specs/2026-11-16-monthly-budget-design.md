# Monthly budget widget — design

## Intent
Let the user track month-to-date spend against a self-set monthly allowance, at a glance, in the popover.

## Goals
- Horizontal bar between the scrolling content and the footer, with a minor tick per day of the current month.
- Marker for the current point in the month; marker for the fraction of allowance spent.
- Spend marker red if ahead of the day marker, green if at or behind.
- Small field on the right to enter the allowance in whole dollars.

## Non-goals
- Forecasting, alerts/notifications, per-project budgets, multiple months.

## Behaviour (decisions)
- Spend = `store.month.total.total` (follows the project filter, matches menu bar).
- Day position = (day-of-month − 1 + fraction of day elapsed) / days-in-month.
- Spend position = spend / allowance, clamped to 1. Tie counts as green.
- Allowance is a non-negative whole number; invalid input is rejected and the previous value kept. Persisted in `UserDefaults` (`monthlyAllowance`), not persisted in snapshot mode.
- Allowance 0 (default): chart is greyed out (muted ticks and day marker, no spend marker). The field stays enabled.
- Shown on both tabs.

## Approaches
1. Pure marker maths in `ClauditCore` + thin SwiftUI view + store property (chosen): testable, matches existing structure.
2. All logic inside the view: less code, untestable. Rejected.

## Left to builder
Exact sizes, colours (system red/green), tick styling, field layout.
