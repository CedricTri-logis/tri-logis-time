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
- Withdrawals are paid at the **original hourly rate** at time of deposit (not current rate)
- Full audit trail: every transaction records hours, rate, amount, reason, who, when
- Balance = SUM(deposits) - SUM(withdrawals), calculated dynamically

**Sick Leave (LNT Art. 79.7):**
- 14 hours/year (2 days × 7h) of paid sick leave
- Year resets January 1 (calendar year, per LNT default)
- Employee must have 3+ months of continuous service to be eligible
- Pay calculated at regular daily wage (current hourly rate × hours)
- No carry-over — unused hours are lost at year end
- The 2 paid days cover illness AND family obligations (combined pool per LNT)

**Locking:** Both hour bank transactions and sick leave usages are locked when `payroll_approvals.status = 'approved'` (existing `check_payroll_lock` trigger).

## Database Schema

### New Table: `hour_bank_transactions`

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | |
| `employee_id` | FK employee_profiles | |
| `payroll_period_start` | DATE | Period this transaction applies to |
| `payroll_period_end` | DATE | |
| `transaction_type` | TEXT ('deposit' \| 'withdrawal') | deposit = hours removed from pay into bank; withdrawal = hours taken from bank added to pay |
| `hours` | NUMERIC | Always positive |
| `hourly_rate` | NUMERIC | Rate frozen at time of transaction (deposit: current rate; withdrawal: original deposit rate) |
| `amount` | NUMERIC | hours × hourly_rate |
| `reason` | TEXT NOT NULL | Admin-provided reason |
| `created_by` | UUID FK auth.users | |
| `created_at` | TIMESTAMPTZ | |

**Unique constraint:** None — multiple transactions per employee per period allowed.
**RLS:** Admins/super_admins full access; employees read-only on own rows.

### New Table: `sick_leave_usages`

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

**Constraint:** CHECK that SUM(hours) for employee+year never exceeds 14h (enforced in RPC).
**RLS:** Admins/super_admins full access; employees read-only on own rows.

### No Balance Table

Balances are computed dynamically:
- **Bank balance** = SUM(hours WHERE type='deposit') - SUM(hours WHERE type='withdrawal')
- **Sick balance** = 14 - SUM(hours WHERE year = current_year)

This avoids sync issues between a balance table and transaction log.

### Locking Integration

Add `hour_bank_transactions` and `sick_leave_usages` to the existing `check_payroll_lock()` trigger. When `payroll_approvals.status = 'approved'` for a period, no INSERT/UPDATE/DELETE is allowed on transactions for that period.

## RPC Functions

### `get_hour_bank_balance(p_employee_id UUID)`
Returns: `{ balance_hours, balance_amount, last_transaction_date }`

### `get_sick_leave_balance(p_employee_id UUID, p_year INTEGER)`
Returns: `{ total_hours: 14, used_hours, remaining_hours }`

### `add_hour_bank_transaction(p_employee_id, p_period_start, p_period_end, p_type, p_hours, p_reason)`
- Validates payroll not locked
- For withdrawal: validates sufficient balance
- For withdrawal: retrieves original hourly_rate from matching deposits (FIFO)
- For deposit: uses employee's current hourly_rate for that date
- Inserts into `hour_bank_transactions`
- Returns created transaction

### `add_sick_leave_usage(p_employee_id, p_period_start, p_period_end, p_hours, p_absence_date, p_reason)`
- Validates payroll not locked
- Validates remaining balance >= p_hours (14h - used this year)
- Validates employee has 3+ months continuous service (LNT requirement)
- Uses current hourly_rate for the absence date
- Inserts into `sick_leave_usages` with year = EXTRACT(YEAR FROM p_absence_date)
- Returns created transaction

### `delete_hour_bank_transaction(p_transaction_id UUID)`
- Validates payroll not locked
- For withdrawal deletion: no extra validation needed
- For deposit deletion: validates remaining bank balance would stay >= 0
- Deletes the transaction

### `delete_sick_leave_usage(p_usage_id UUID)`
- Validates payroll not locked
- Deletes the usage (hours return to annual pool)

### `get_hour_bank_history(p_employee_id UUID)`
Returns all transactions (bank + sick leave) ordered by created_at DESC, with columns: date, type, hours, rate, amount, period, reason, created_by name.

### Modified: `get_payroll_period_report`
Add columns to output:
- `bank_deposit_hours` — hours deposited into bank this period
- `bank_withdrawal_hours` — hours withdrawn from bank this period
- `bank_withdrawal_amount` — monetary value of withdrawals (at original rate)
- `sick_leave_hours` — sick hours used this period
- `sick_leave_amount` — monetary value of sick hours
- `bank_balance` — current total bank balance
- `sick_leave_remaining` — remaining sick hours for the year

Adjust `total_amount` calculation:
```
total_amount = base_amount
  - (bank_deposit_hours × current_rate)    -- deposits reduce pay
  + bank_withdrawal_amount                  -- withdrawals add pay (at original rate)
  + sick_leave_amount                       -- sick leave adds pay
  + premium_amount + callback_bonus_amount  -- existing
```

## Dashboard Components

### Modified: `payroll-summary-table.tsx`
- Add 4 columns after "Refusees": **Banque +/-**, **Solde banque**, **Maladie**, **Solde maladie**
- Add "Ajustements" button per employee row
- Bank +/- shows: red negative for withdrawals (added to pay), green positive for deposits (removed from pay)
- Solde banque: blue badge with current balance
- Maladie: green value if hours used this period, dash if none
- Solde maladie: green badge with remaining hours

### New: `PayrollAdjustmentsModal`
- Triggered by "Ajustements" button
- **Bank section:** balance bar (current balance + last transaction), operation dropdown (deposit/withdraw), hours input, reason field, rate display
- **Sick leave section:** balance bar (remaining/used this year, eligibility date), hours input, absence date picker, reason field
- **Impact preview:** shows how adjustments change total hours and pay for this period
- "Appliquer les ajustements" button submits both in one action
- Refreshes payroll table on close

### New: `HourBankHistoryDialog`
- Accessible from modal or from a dedicated button
- Full transaction log table: date, type (badge), hours, rate, value, period, reason, by
- Summary footer: total deposited, total withdrawn, sick leave used this year

### Modified: `use-payroll-report.ts`
- Integrate new fields into `PayrollEmployeeSummary`
- Aggregate bank_net_hours and sick_leave_hours in category subtotals and grand total

### Modified: `payroll.ts` (types)
- Add to `PayrollReportRow`: bank_deposit_hours, bank_withdrawal_hours, bank_withdrawal_amount, sick_leave_hours, sick_leave_amount, bank_balance, sick_leave_remaining
- Add to `PayrollEmployeeSummary`: same aggregated fields

### Modified: `export-payroll-excel.ts`
- Add Banque +/- and Maladie columns to Excel export

## No Flutter Changes

This feature is admin-only — no changes to the mobile app.

## Mockup

Interactive mockup: `.mockups/bank-hours-design.html` (3 tabs: table, modal, history)
