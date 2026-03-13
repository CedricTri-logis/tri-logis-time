# Lunch Break Feature Design

Date: 2026-03-06

## Overview

Employees can declare lunch breaks during active shifts via a dedicated button. GPS tracking pauses during lunch, the break is logged as explicit timeline events, and lunch time is auto-deducted from paid hours.

## Decisions

| Question | Decision |
|----------|----------|
| GPS during lunch | Stops (saves battery, clean separation from gaps) |
| Duration limit | Open-ended, employee ends manually |
| Multiple breaks | Yes, unlimited per shift |
| UI placement | Compact pill button below the 200x200 clock button |
| Dashboard display | Lunch start/end in clock indicator column (Column 2) with lunch icon |
| Paid hours | Auto-subtracted, no admin action needed |

---

## Database

### New table: `lunch_breaks`

```sql
CREATE TABLE lunch_breaks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,           -- NULL = currently on lunch
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_lunch_breaks_shift_id ON lunch_breaks(shift_id);
CREATE INDEX idx_lunch_breaks_employee_date ON lunch_breaks(employee_id, started_at DESC);
```

RLS policies mirror shifts: employees see own, supervisors see their employees, admins see all.

### Local SQLCipher table: `local_lunch_breaks`

```sql
CREATE TABLE local_lunch_breaks (
    id TEXT PRIMARY KEY,
    shift_id TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    started_at TEXT NOT NULL,        -- ISO 8601
    ended_at TEXT,                   -- NULL = on lunch
    sync_status TEXT NOT NULL DEFAULT 'pending',
    server_id TEXT,
    created_at TEXT NOT NULL
);
```

---

## RPC Changes

### `get_day_approval_detail` — New UNION stages

Add two new activity types to the existing 5 (stop, trip, clock_in, clock_out, gap):

**`lunch_start`** — emitted at `started_at`:
- `activity_type = 'lunch_start'`
- `activity_id = lunch_breaks.id`
- `duration_minutes = 0`
- `auto_status = 'approved'`
- `auto_reason = 'Pause diner'`
- Not approvable (no approve/reject buttons in UI)

**`lunch_end`** — emitted at `ended_at`:
- `activity_type = 'lunch_end'`
- `activity_id = lunch_breaks.id`
- `duration_minutes = lunch break duration (ended_at - started_at)`
- `auto_status = 'approved'`
- `auto_reason = 'Pause diner'`
- Not approvable

### Gap detection exclusion

The gap detection algorithm (migration 131) builds a timeline of covered periods. Lunch breaks must be added to the timeline as covered events so they do NOT generate untracked gaps.

In the timeline event builder:
```
-- Add lunch breaks as covered periods
UNION ALL
SELECT started_at AS event_start, ended_at AS event_end
FROM lunch_breaks
WHERE shift_id = ANY(shift_ids) AND ended_at IS NOT NULL
```

### Summary calculation change

```
lunch_minutes = SUM(lunch_break durations for the day)
total_shift_minutes = raw shift duration - lunch_minutes   -- auto-deducted
approved_minutes = SUM(duration WHERE final_status = 'approved')  -- unchanged
rejected_minutes = SUM(duration WHERE final_status = 'rejected')  -- unchanged
```

New field in summary JSONB: `lunch_minutes INTEGER`.

### `get_weekly_approval_summary` changes

- Add `lunch_minutes` to each day entry
- `total_shift_minutes` returned after lunch deduction
- Lunch does NOT increment `needs_review_count`

---

## Dashboard (Next.js)

### `day-approval-detail.tsx`

**Summary stats grid** — new stat box:
- Label: "Diner" (or "Pause")
- Icon: Utensils/fork-knife
- Background: neutral blue/slate
- Value: total lunch minutes for the day (e.g., "45 min")

**Activity table** — lunch_start and lunch_end rows:

| Column | lunch_start | lunch_end |
|--------|-------------|-----------|
| Action (approve/reject) | None | None |
| Clock indicator (Col 2) | Lunch icon (Utensils) | Lunch icon (Utensils) |
| Type icon (Col 3) | "Pause diner" | "Fin pause" |
| Duree (Col 4) | — | Lunch duration |
| Details (Col 5) | "Debut pause diner" | "Fin pause diner" |
| Horaire (Col 6) | Timestamp | Timestamp |
| Distance (Col 7) | — | — |
| Expand (Col 8) | — | — |

**Row styling**: Neutral slate/gray-50 background, no colored left border. Visually distinct from approved (green), rejected (red), and needs_review (amber) rows.

### `approval-grid.tsx`

Day cell tooltip adds lunch info: e.g., "7h30 travaille, 45min diner".

### `merge-clock-events.ts`

Extend merging logic to handle `lunch_start` and `lunch_end` — if a lunch timestamp is within 60s of a stop boundary, merge visually (same pattern as clock_in/clock_out merging).

### TypeScript types

```typescript
// Extend activity_type union
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch_start' | 'lunch_end';

// Add to WeeklyDayEntry
lunch_minutes: number;

// Add to DayApprovalDetail summary
lunch_minutes: number;
```

---

## Mobile App (Flutter)

### UI: Lunch button

- **Location**: Below the 200x200 clock button on shift_dashboard_screen
- **Shape**: Compact pill/rounded-rectangle button
- **States**:
  - Shift inactive → hidden
  - Shift active, not on lunch → "PAUSE DINER" (orange/yellow)
  - On lunch → "FIN PAUSE" (green)
- **During lunch**:
  - Clock button ("TERMINER Le Quart") disabled with reduced opacity
  - Employee must end lunch before ending shift

### Behavior

1. Tap "PAUSE DINER":
   - Create `local_lunch_breaks` record with `started_at = now`, `ended_at = NULL`
   - Stop GPS tracking (pause foreground service)
   - Update iOS Live Activity to show "En pause diner"
   - Update shift state to indicate lunch in progress

2. Tap "FIN PAUSE":
   - Update `local_lunch_breaks` record with `ended_at = now`
   - Resume GPS tracking (restart foreground service)
   - Update iOS Live Activity back to normal shift timer
   - Sync lunch break to Supabase when connected

3. Multiple breaks: button reappears after each lunch ends

### Provider: `lunch_break_provider.dart`

- Watches active shift state
- Manages current lunch break (start/end)
- Exposes: `isOnLunch`, `currentLunchBreak`, `lunchBreaksForShift`
- Handles offline sync via existing sync infrastructure

### Sync

- Follows same offline-first pattern as shifts and GPS points
- `local_lunch_breaks` synced on connectivity restore
- Upsert to `lunch_breaks` table on server

---

## Reports & Exports

### CSV export
Add columns: `Nombre de pauses`, `Duree pauses (min)`, `Heures payees`

### PDF export
Add lunch break section showing each break's start/end time and total lunch duration. Paid hours = shift duration minus lunch.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Employee ends shift while on lunch | Disabled — must end lunch first |
| App killed during lunch | On restart, detect open lunch break (ended_at = NULL), show "FIN PAUSE" state |
| Midnight shift rollover during lunch | Lunch break spans midnight, attributed to the shift's start date |
| Server-side shift closure during lunch | Auto-close lunch break with ended_at = shift closure time |
| Accidental lunch tap | Employee taps "FIN PAUSE" immediately; short lunch (<1 min) still recorded, admin can see in timeline |
