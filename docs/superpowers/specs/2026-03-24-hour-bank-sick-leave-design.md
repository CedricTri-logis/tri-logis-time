# Hour Bank & Sick Leave — Design Spec

**Date:** 2026-03-24
**Feature:** Heures en banque et heures maladie sur la paie
**Status:** Approved

## Summary

Allow admins to bank hours (deposit/withdraw) and apply paid sick leave hours during payroll approval. Both adjustments happen at the payroll period level via a modal dialog accessible from the payroll summary table.

### Business Rules

**Hour Bank:**
- Admin can deposit hours (removed from current pay, stored in bank) or withdraw hours (added to current pay from bank)
- No maximum balance limit — admin manages at their discretion
- **Bank stores value in dollars.** Deposit: hours × current rate = $ added to bank. Withdrawal: admin enters hours, system converts at current rate (hours × current rate = $ removed from bank). The bank is a dollar account; hours are just the input/output interface.
- Balance cannot go negative — withdrawals are blocked if insufficient funds
- Full audit trail: every transaction records hours, rate, amount, reason, who, when
- Balance = SUM(deposit amounts) - SUM(withdrawal amounts), calculated dynamically
- **Solde displayed as both:** dollars (stable value) and hours equivalent (dollars ÷ current rate, fluctuates)
- **Hourly employees only** — annual-salary employees cannot use hour banking

**Sick Leave (LNT Art. 79.7):**
- 14 hours/year (2 days × 7h) of paid sick leave
- Year resets January 1 (calendar year, per LNT default)
- Employee must have 3+ months of continuous service to be eligible
  - Eligibility determined by first shift date: `MIN(clocked_in_at) FROM shifts WHERE employee_id = ?`
- Pay calculated at regular daily wage (current hourly rate × hours)
- No carry-over — unused hours are lost at year end
- The 2 paid days cover illness AND family obligations (combined pool per LNT)
- Available to both hourly and annual-salary employees

**Locking:** Both hour bank transactions and sick leave usages are locked when `payroll_approvals.status = 'approved'` (existing `check_payroll_lock` trigger).

## Database Schema

### New Table: `hour_bank_transactions`

Immutable insert/delete only — no UPDATE allowed.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | |
| `employee_id` | FK employee_profiles | |
| `payroll_period_start` | DATE | Period this transaction applies to |
| `payroll_period_end` | DATE | |
| `transaction_type` | TEXT ('deposit' \| 'withdrawal') | deposit = hours removed from pay into bank ($); withdrawal = hours added to pay from bank ($) |
| `hours` | NUMERIC | Always positive — the hours the admin entered |
| `hourly_rate` | NUMERIC | Employee's current rate at time of transaction |
| `amount` | NUMERIC | hours × hourly_rate (dollar value moved in/out of bank) |
| `reason` | TEXT NOT NULL | Admin-provided reason |
| `created_by` | UUID FK auth.users | |
| `created_at` | TIMESTAMPTZ | |

**Unique constraint:** None — multiple transactions per employee per period allowed.
**Indexes:**
- `(employee_id, payroll_period_start)` — period lookups
- `(employee_id, transaction_type)` — balance computation
**RLS:** Admins/super_admins full access; employees read-only on own rows.

### New Table: `sick_leave_usages`

Immutable insert/delete only — no UPDATE allowed.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | |
| `employee_id` | FK employee_profiles | |
| `payroll_period_start` | DATE | Period this usage applies to |
| `payroll_period_end` | DATE | |
| `hours` | NUMERIC | Hours used (always positive) |
| `absence_date` | DATE | Date of actual absence |
| `hourly_rate` | NUMERIC | Rate at time of absence |
| `amount` | NUMERIC | hours × hourly_rate |
| `reason` | TEXT NOT NULL | e.g., "Grippe", "Rendez-vous medical" |
| `year` | INTEGER | Reference year (for annual balance calc) |
| `created_by` | UUID FK auth.users | |
| `created_at` | TIMESTAMPTZ | |

**Constraints:**
- `CHECK (absence_date BETWEEN payroll_period_start AND payroll_period_end)` — absence must fall within pay period
- `CHECK (year = EXTRACT(YEAR FROM absence_date))` — year always matches absence date
- SUM(hours) per employee+year <= 14h — enforced in RPC + trigger safety net

**Indexes:**
- `(employee_id, year)` — annual balance computation
- `(employee_id, payroll_period_start)` — period lookups

**RLS:** Admins/super_admins full access; employees read-only on own rows.

### No Balance Table

Balances are computed dynamically:
- **Bank balance ($)** = SUM(amount WHERE type='deposit') - SUM(amount WHERE type='withdrawal')
- **Bank balance (hours)** = bank_balance_dollars ÷ employee's current hourly rate
- **Sick balance** = 14 - SUM(hours WHERE year = current_year)

This avoids sync issues between a balance table and transaction log.

### Locking Integration

Add `hour_bank_transactions` and `sick_leave_usages` to the existing `check_payroll_lock()` trigger:
- New `ELSIF` branches for `TG_TABLE_NAME = 'hour_bank_transactions'` and `'sick_leave_usages'`
- These tables use `payroll_period_start`/`payroll_period_end` (period-based), unlike existing tables which use a single date. The trigger checks overlap with approved `payroll_approvals` periods.
- Create triggers: `trg_payroll_lock_hour_bank_transactions` and `trg_payroll_lock_sick_leave_usages`

### Immutability

Both tables are insert/delete only. An `ON UPDATE` trigger raises an exception to prevent modifications. To correct an error, the admin deletes the transaction and creates a new one.

## RPC Functions

### `get_hour_bank_balance(p_employee_id UUID)`
Returns: `{ balance_dollars, balance_hours, current_hourly_rate, last_transaction_date }`
- `balance_dollars` = SUM(deposit amounts) - SUM(withdrawal amounts)
- `balance_hours` = balance_dollars ÷ current hourly rate
- Only returns data for hourly employees; raises exception for annual employees

### `get_sick_leave_balance(p_employee_id UUID, p_year INTEGER)`
Returns: `{ total_hours: 14, used_hours, remaining_hours, eligible: BOOLEAN, first_shift_date }`
- `eligible` = first shift date is at least 3 months before current date
- `first_shift_date` = MIN(clocked_in_at) FROM shifts

### `add_hour_bank_transaction(p_employee_id, p_period_start, p_period_end, p_type, p_hours, p_reason)`
- Validates employee is hourly (not annual salary)
- Validates payroll not locked
- Looks up employee's current hourly_rate for the period
- Computes amount = p_hours × hourly_rate
- For withdrawal: validates balance_dollars >= amount (cannot go negative)
- Inserts into `hour_bank_transactions`
- Returns created transaction + updated balance

### `add_sick_leave_usage(p_employee_id, p_period_start, p_period_end, p_hours, p_absence_date, p_reason)`
- Validates payroll not locked
- Validates absence_date falls within period
- Validates remaining balance >= p_hours (14h - used this year)
- Validates employee has 3+ months continuous service: `MIN(clocked_in_at) FROM shifts` is at least 3 months before `p_absence_date`
- Looks up current hourly_rate for the absence date
- Inserts into `sick_leave_usages` with year = EXTRACT(YEAR FROM p_absence_date)
- Returns created transaction + updated balance

### `delete_hour_bank_transaction(p_transaction_id UUID)`
- Validates payroll not locked
- For deposit deletion: validates remaining bank balance (dollars) would stay >= 0 after removal
- For withdrawal deletion: no extra validation needed (balance goes up)
- Deletes the transaction

### `delete_sick_leave_usage(p_usage_id UUID)`
- Validates payroll not locked
- Deletes the usage (hours return to annual pool)

### `get_hour_bank_history(p_employee_id UUID)`
Returns all transactions (bank + sick leave) ordered by created_at DESC.
Return type columns:
- `date` (TIMESTAMPTZ), `type` ('deposit' | 'withdrawal' | 'sick_leave'), `hours` (NUMERIC), `hourly_rate` (NUMERIC), `amount` (NUMERIC), `period_start` (DATE), `period_end` (DATE), `reason` (TEXT), `created_by_name` (TEXT), `transaction_id` (UUID), `can_delete` (BOOLEAN — false if payroll locked)

### Modified: `get_payroll_period_report`
Add columns to output (per-employee, on first day row only — same pattern as `period_salary`):
- `bank_deposit_hours` — hours deposited into bank this period
- `bank_deposit_amount` — dollar value of deposits
- `bank_withdrawal_hours` — hours withdrawn from bank this period
- `bank_withdrawal_amount` — dollar value of withdrawals
- `sick_leave_hours` — sick hours used this period
- `sick_leave_amount` — dollar value of sick hours
- `bank_balance_dollars` — current total bank balance in dollars
- `bank_balance_hours` — current bank balance converted to hours at current rate
- `sick_leave_remaining` — remaining sick hours for the year

Adjust `total_amount` calculation:
```
total_amount = base_amount
  - bank_deposit_amount                     -- deposits reduce pay
  + bank_withdrawal_amount                  -- withdrawals add pay
  + sick_leave_amount                       -- sick leave adds pay
  + premium_amount + callback_bonus_amount  -- existing
```

## Dashboard Components

### Modified: `payroll-summary-table.tsx`
- Add 4 columns after "Refusees": **Banque +/-**, **Solde banque**, **Maladie**, **Solde maladie**
- Add "Ajustements" button per employee row (hidden for annual-salary employees' bank section)
- Bank +/- shows: red negative for deposits (removed from pay), green positive for withdrawals (added to pay)
- Solde banque: blue badge showing "280$ (9h20)" format (dollars + hours equivalent)
- Maladie: green value if hours used this period, dash if none
- Solde maladie: green badge with remaining hours out of 14

### New: `PayrollAdjustmentsModal`
- Triggered by "Ajustements" button
- **Bank section:** balance bar showing dollars + hours equivalent, operation dropdown (deposit/withdraw), hours input, reason field, computed dollar amount displayed
- **Sick leave section:** balance bar (remaining/used this year, eligibility status based on first shift date), hours input, absence date picker, reason field
- **Impact preview:** shows how adjustments change total hours and pay for this period
- "Appliquer les ajustements" button submits both via sequential RPC calls. If the first call succeeds and the second fails, the first is not rolled back — admin sees an error and can retry or delete.
- Refreshes payroll table on close via existing `silentRefetch` from `use-payroll-report.ts`

### New: `HourBankHistoryDialog`
- Accessible from modal or from a dedicated button
- Full transaction log table: date, type badge (Depot banque / Retrait banque / Maladie), hours, rate, dollar value, period, reason, by
- Delete button per row (disabled if payroll locked, calls `delete_hour_bank_transaction` or `delete_sick_leave_usage`)
- Summary footer: total deposited ($), total withdrawn ($), current balance ($), sick leave used this year

### Modified: `use-payroll-report.ts`
- Integrate new fields into `PayrollEmployeeSummary`
- Aggregate bank amounts and sick_leave_hours in category subtotals and grand total

### Modified: `payroll.ts` (types)
- Add to `PayrollReportRow`: bank_deposit_hours, bank_deposit_amount, bank_withdrawal_hours, bank_withdrawal_amount, sick_leave_hours, sick_leave_amount, bank_balance_dollars, bank_balance_hours, sick_leave_remaining
- Add to `PayrollEmployeeSummary`: same aggregated fields

### Modified: `export-payroll-excel.ts`
- Add Banque +/- ($) and Maladie (h) columns to Excel export

## No Flutter Changes

This feature is admin-only — no changes to the mobile app.

## Mockup

Interactive mockup: `.mockups/bank-hours-design.html` (3 tabs: table, modal, history)
