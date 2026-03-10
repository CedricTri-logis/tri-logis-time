# Callback Shifts (Rappels au travail) & Employee Categories

**Date:** 2026-03-10
**Status:** Approved
**Branch:** 008-employee-shift-dashboard

## Problem

Employees sometimes get called back to work outside regular hours (emergencies, maintenance). These "callbacks" (rappels au travail) need to be tracked, visually identified, and billed according to Quebec Labour Standards (Article 58, Loi sur les normes du travail) which mandate a minimum 3-hour indemnity.

Additionally, employees perform different roles (renovation, maintenance, cleaning, admin) that can change over time and overlap. The system needs to track these categories by period.

## Legal Context — Article 58 LNT (Quebec)

- An employee who reports to work and works fewer than 3 consecutive hours is entitled to an indemnity equal to 3 hours at their regular hourly rate.
- Each distinct callback (where the employee physically displaces to the workplace) triggers the minimum.
- Exception: force majeure.
- If overtime (>40h/week) gives a higher amount (Article 55, 1.5x rate), the employee gets the higher of the two.

## Design

### Callback Detection

- **Auto-detection:** Any shift where `clocked_in_at` falls between 17:00 and 05:00 (America/Montreal timezone) is automatically flagged as `call`. Applies to all employees, 7 days a week.
- **Manual override:** A supervisor can mark any shift as `call` or remove the `call` flag, regardless of clock-in time.
- **Mobile app:** Detection is silent. The employee clocks in normally. The "Rappel" tag appears only in their shift history.

### Minimum 3-Hour Billing with Grouping

When a shift is classified as `call` and lasts fewer than 3 hours, it is billed as 3 hours minimum.

**Grouping logic for multiple calls in the same day:**

1. Call 1 starts → opens a 3-hour billing window from its start time.
2. If Call 2 starts **within** the billing window of Call 1 → Call 2 is grouped with Call 1 (extension, not a new minimum).
3. If Call 2 extends beyond the original 3-hour window, the window extends to the end of Call 2.
4. If a new call starts **after** the billing window has ended → new 3-hour minimum.

**Example:**
- Call 1: 19:00–19:45 → window = 19:00–22:00
- Call 2: 20:30–21:15 → within window → grouped → billed = 3h total
- Call 3: 23:30–00:15 → outside window → new 3h minimum
- Total billed: 6h (3h + 3h)

### Employee Categories

Employees can be assigned one or more categories simultaneously, tracked by period:
- `renovation` — Renovation
- `entretien` — Maintenance
- `menage` — Cleaning
- `admin` — Administration

An employee can have multiple active categories at the same time (e.g., ménage + admin). Categories are managed from the employee detail page in the dashboard.

## Data Model

### Shifts table (new columns)

```sql
ALTER TABLE shifts ADD COLUMN shift_type TEXT NOT NULL DEFAULT 'regular';
-- Values: 'regular', 'call'

ALTER TABLE shifts ADD COLUMN shift_type_source TEXT NOT NULL DEFAULT 'auto';
-- Values: 'auto', 'manual'

ALTER TABLE shifts ADD COLUMN shift_type_changed_by UUID REFERENCES employee_profiles(id);
-- NULL when auto-detected, set when supervisor overrides
```

### Trigger: auto-detect callback on insert

```sql
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
  local_hour INTEGER;
BEGIN
  local_hour := EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal');
  -- Between 17:00 (17) and 04:59 (< 5)
  IF local_hour >= 17 OR local_hour < 5 THEN
    NEW.shift_type := 'call';
    NEW.shift_type_source := 'auto';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_shift_type
  BEFORE INSERT ON shifts
  FOR EACH ROW EXECUTE FUNCTION set_shift_type_on_insert();
```

### New table: employee_categories

```sql
CREATE TABLE employee_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK (category IN ('renovation', 'entretien', 'menage', 'admin')),
  started_at DATE NOT NULL,
  ended_at DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Prevent exact duplicate periods for same employee+category
  CONSTRAINT no_duplicate_category_period UNIQUE (employee_id, category, started_at)
);

CREATE INDEX idx_employee_categories_employee ON employee_categories(employee_id);
CREATE INDEX idx_employee_categories_active ON employee_categories(employee_id) WHERE ended_at IS NULL;
```

### RPC: update_shift_type

```sql
CREATE OR REPLACE FUNCTION update_shift_type(
  p_shift_id UUID,
  p_shift_type TEXT,
  p_changed_by UUID
) RETURNS VOID AS $$
BEGIN
  UPDATE shifts
  SET shift_type = p_shift_type,
      shift_type_source = 'manual',
      shift_type_changed_by = p_changed_by
  WHERE id = p_shift_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Approval RPCs updates

**`get_weekly_approval_summary`:** Add to each day entry:
- `call_count` — number of call shifts that day
- `call_billed_minutes` — total billed minutes for calls (with 3h minimum + grouping)

**`get_day_approval_detail`:** Add to each shift/activity:
- `shift_type` — 'regular' or 'call'
- `shift_type_source` — 'auto' or 'manual'
- `billed_minutes` — actual minutes or 3h minimum (whichever is higher), with grouping applied

**Grouping calculation (SQL pseudo-logic):**
1. Order call shifts by `clocked_in_at` for a given employee+day
2. First call opens a window: `MAX(clocked_in_at + 3h, clocked_out_at)`
3. Next call: if `clocked_in_at < window_end` → extend window to `MAX(window_end, clocked_out_at)`
4. Else → new group, new 3h window
5. Each group's billed minutes = `MAX(actual_total_minutes, 180)`

## UI Changes

### Dashboard — Approval Grid (`approval-grid.tsx`)

- Day cells containing calls show a distinct visual indicator (colored border/background + phone icon)
- Tooltip: "X rappel(s) — Yh facturées"

### Dashboard — Day Approval Detail (`day-approval-detail.tsx`)

- Call shifts have a distinct header spanning the full width (different color from regular shifts)
- Displays:
  - Actual hours worked
  - Billed hours (min 3h or grouped time)
  - Source: "Auto (17h–5h)" or "Manuel"
- Action buttons per shift:
  - "Confirmer rappel" / "Retirer rappel" — toggles call classification
  - Integrated in existing approval flow

### Dashboard — Employee Detail (`/dashboard/employees/{id}`)

- New "Catégories" section with period table
- Columns: category, start date, end date, actions (close/delete)
- "Ajouter une catégorie" button
- Multiple active categories shown simultaneously

### Flutter — Shift History

- "Rappel" tag on call shifts in the history list
- Shift detail: "Rappel — minimum 3h" mention when applicable

### Flutter — Shift Model Updates

- `Shift` model: add `shiftType` field
- `LocalShift` model: add `shiftType` in SQLCipher schema
- No changes to clock-in/out flow (detection is silent, DB-side)

## Out of Scope

- Call-specific reports/statistics (future)
- Call-specific overtime calculation display (standard overtime rules apply)
- Mobile notification to employee when shift is flagged as call
- Category-based call eligibility rules (all employees treated equally for calls)
