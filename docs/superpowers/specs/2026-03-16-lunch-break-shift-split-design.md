# Lunch Break → Shift Split Design

**Date:** 2026-03-16
**Status:** Approved

## Problem

Lunch breaks are currently a separate entity (`lunch_breaks` table) linked to a shift that remains active during the break. This causes:

1. **Overlapping timestamps** — GPS detects an employee arriving at a work location (13:10) before they manually end their lunch (13:11), creating confusing overlap in the approval detail view.
2. **Dual data model** — lunch is tracked separately from shifts, requiring special handling in every RPC, dashboard component, and Flutter widget.
3. **No natural segmentation** — a shift spanning 08:00-17:00 with a lunch break is displayed as one monolithic block instead of two distinct work segments.

## Solution

Treat lunch breaks as shift boundaries. When an employee starts a lunch break, the current shift closes (`clock_out_reason = 'lunch'`). When they end the break, a new shift opens with the same `work_body_id`. The lunch break becomes the implicit gap between two shifts in the same work body.

## Data Model Changes

### `shifts` table — add 1 column, extend 1

| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `work_body_id` | `UUID` | `gen_random_uuid()` | Groups shifts belonging to the same continuous work body. First shift generates the ID; post-lunch segments inherit it. Callbacks/rappels get a different `work_body_id`. |
| `clock_out_reason` | (existing) | — | Add `'lunch'` to the set of valid values. Currently has: `manual`, `auto_zombie_cleanup`, `midnight_auto_cleanup`, `admin_cleanup`, `no_gps_auto_close`, `midnight_auto_close`, `server_reconciliation`, `auto_clock_in_cleanup`, `manual_admin_cleanup`, `admin_manual_close`. |

### `lunch_breaks` table — drop after migration

The table is eliminated. Lunch duration is derived from shifts:
- **Lunch start** = `clocked_out_at` of shift where `clock_out_reason = 'lunch'`
- **Lunch end** = `clocked_in_at` of the next shift with the same `work_body_id`
- **Lunch duration** = difference between the two

### Deriving lunch data from shifts (SQL pattern)

```sql
-- Find lunch breaks for a given employee on a given day
WITH shift_data AS (
  SELECT id, work_body_id, employee_id, clocked_in_at, clocked_out_at,
         clock_out_reason,
         LEAD(clocked_in_at) OVER (PARTITION BY work_body_id ORDER BY clocked_in_at) AS next_clock_in
  FROM shifts
  WHERE employee_id = p_employee_id
    AND (clocked_in_at AT TIME ZONE 'America/Toronto')::DATE = p_date
    AND status = 'completed'
)
SELECT
  clocked_out_at AS lunch_started_at,
  next_clock_in AS lunch_ended_at,
  EXTRACT(EPOCH FROM (next_clock_in - clocked_out_at))::INTEGER / 60 AS lunch_minutes
FROM shift_data
WHERE clock_out_reason = 'lunch'
  AND next_clock_in IS NOT NULL;
```

## Retroactive Data Migration

### Scope

- **56 lunch breaks** (54 completed, 2 open)
- **16 employees** affected
- **9 child tables** with `shift_id` FK: `gps_points`, `stationary_clusters`, `trips`, `gps_gaps`, `work_sessions`, `cleaning_sessions`, `maintenance_sessions`, `shift_time_edits`, `lunch_breaks`

### Migration steps

For each completed lunch break (`ended_at IS NOT NULL`):

1. **Assign `work_body_id`** to the parent shift (if not already assigned).
2. **Split the shift**: Close the pre-lunch segment at `lunch.started_at` with `clock_out_reason = 'lunch'`. Create a new post-lunch shift from `lunch.ended_at` to the original `clocked_out_at`, inheriting `work_body_id`, `employee_id`, `shift_type`, `shift_type_source`, `app_version`.
3. **Redistribute child records** between pre-lunch and post-lunch segments based on timestamps:
   - `gps_points`: by `captured_at`
   - `stationary_clusters`: by `started_at`
   - `trips`: by `started_at`
   - `gps_gaps`: by timestamp
   - `work_sessions`: by `started_at`
   - `cleaning_sessions`, `maintenance_sessions`: by `started_at`
   - `shift_time_edits`: remain on the original shift (they reference the pre-split shift)
4. **Copy clock-out metadata** to the post-lunch segment: `clock_out_location`, `clock_out_accuracy`, `clock_out_cluster_id`, `clock_out_location_id`, `clocked_out_at`, original `clock_out_reason`. The pre-lunch segment gets NULL for these (except `clocked_out_at = lunch.started_at` and `clock_out_reason = 'lunch'`).
5. **Assign `work_body_id`** to all shifts without lunch breaks (1 shift = 1 work body).

### Edge cases

- **2 open lunch breaks**:
  - Jessy Mainville: lunch open on completed shift (orphan) — close the lunch at `shift.clocked_out_at`, then split normally.
  - Fatima Zahra Rechka: lunch open on active shift — skip during migration (will be handled by new app logic going forward).
- **Multiple lunch breaks per shift** (e.g., Kouma Baraka, Irene Pepin have 2+ per shift): split iteratively, creating N+1 segments for N lunch breaks. Each intermediate segment gets `clock_out_reason = 'lunch'`.

## Trigger Adaptations

### `trg_set_shift_type` (BEFORE INSERT)

Currently auto-classifies shifts as `regular` or `call` based on clock-in time (17h-5h = call). When creating a post-lunch segment, it must **inherit the parent's shift_type** instead of re-classifying. Solution: if `work_body_id` already exists in another shift, copy that shift's `shift_type` and `shift_type_source`.

### `trg_auto_close_sessions_on_shift_complete` (AFTER UPDATE)

Currently auto-closes work_sessions when a shift completes. When closing for lunch (`clock_out_reason = 'lunch'`), work_sessions should **NOT be auto-closed** — the employee is coming back. Solution: skip trigger logic when `NEW.clock_out_reason = 'lunch'`.

## RPC Changes (7 functions)

All 7 functions that currently query `lunch_breaks` must be rewritten to derive lunch data from shifts using the `work_body_id` + `clock_out_reason = 'lunch'` pattern:

| Function | Change |
|----------|--------|
| `_get_day_approval_detail_base` | Replace `lunch_data` CTE with shift-derived lunch. Group activities by `work_body_id` for display. Lunch = gap between segments. |
| `get_weekly_approval_summary` | Replace lunch_minutes calculation from `lunch_breaks` to shift gaps. |
| `get_weekly_breakdown_totals` | Same: derive lunch from shifts. Remove lunch adjacency detection for trips (trips adjacent to a shift boundary where `clock_out_reason = 'lunch'` are lunch-adjacent). |
| `get_monitored_team` | Detect "on lunch" status: employee has a recently completed shift with `clock_out_reason = 'lunch'` and no subsequent active shift in the same `work_body_id`. |
| `save_activity_override` | Remove lunch-specific logic (lunch activities no longer exist as a type). |
| `remove_activity_override` | Same. |
| `server_close_all_sessions` | Remove lunch_breaks handling. |

## Flutter App Changes (17 files)

### Core logic changes

| File | Change |
|------|--------|
| `lunch_break_provider.dart` | **Rewrite**: `startLunchBreak()` → close active shift with `clock_out_reason = 'lunch'`, pause GPS. `endLunchBreak()` → create new shift with same `work_body_id`, resume GPS. |
| `lunch_break.dart` (model) | **Delete**: no longer needed. |
| `lunch_break_button.dart` (widget) | **Keep** but simplify: button still starts/ends lunch, but underlying logic changes to shift close/open. |
| `shift_provider.dart` | Add `work_body_id` awareness. When resuming from lunch, provide the `work_body_id` of the previous shift. |
| `tracking_provider.dart` | `pauseForLunch()` unchanged (still pauses GPS). |
| `local_database.dart` | Drop `lunch_breaks` local table. Add `work_body_id` and use `clock_out_reason` column on local shifts table. |
| `sync_service.dart` | Remove `_syncLunchBreaks()`. Shifts sync normally with the new columns. |

### UI/display changes

| File | Change |
|------|--------|
| `shift_dashboard_screen.dart` | Group shifts by `work_body_id` for display. Show segments within a work body. |
| `shift_detail_screen.dart` | Show work body with segments, lunch gaps between them. |
| `shift_status_card.dart` | Show "En pause dîner" when last shift has `clock_out_reason = 'lunch'` and no active shift. |
| `shift_timer.dart` | Pause timer during lunch (between segments). |
| `shift_summary_card.dart` | Calculate total work body duration minus lunch gaps. |
| `shift_card.dart` | Display work body grouping. |
| `activity_timeline.dart` | Show lunch as gap between shift segments. |
| `active_work_session_card.dart` | Handle lunch state transition. |
| `work_session_history_list.dart` | Group by work body. |
| `day_approval.dart` (model) | Remove lunch_minutes from separate field; derive from shift gaps. |

## Dashboard Changes (10 files)

| File | Change |
|------|--------|
| `approval-grid.tsx` | Lunch minutes derived from shift gaps in weekly summary. |
| `day-approval-detail.tsx` | Display work body with segments. Lunch row = gap between segments (collapsible, shows sub-activities). Remove `nestLunchActivities`. |
| `approval-rows.tsx` | `LunchGroupRow` renders the gap between shift segments instead of a standalone lunch activity. |
| `approval-utils.ts` | Remove `nestLunchActivities`. Add `groupByWorkBody` to group shifts sharing a `work_body_id`. |
| `merge-clock-events.ts` | Remove lunch handling from clock event merging. |
| `mileage.ts` (types) | Remove `'lunch'` from `activity_type`. Add `work_body_id` to shift types. `lunch_minutes` derived, not stored. |
| `team-list.tsx` | Detect "on lunch" from shift data. |
| `monitoring.ts` (types) | Update monitoring status types. |
| `use-monitoring-badges.ts` | Detect lunch status from shift gaps. |
| `sidebar.tsx` | No change (just has French text "évaluation"). |

## Migration Order

1. **Phase 1 — Database**: Add columns to `shifts`, run retroactive migration, update triggers, rewrite RPCs, drop `lunch_breaks` table.
2. **Phase 2 — Flutter app**: Update providers/services/local DB to use new model. Deploy new app version.
3. **Phase 3 — Dashboard**: Update types, components, and display logic.

**Critical constraint**: Phase 1 (DB) and Phase 3 (dashboard) should deploy together since the RPCs and dashboard code must match. Phase 2 (Flutter) can deploy slightly after since the old app version will fail gracefully on lunch operations until updated.

## Not In Scope

- Changing how callbacks/rappels are grouped (they already have separate shifts).
- Adding new UI for managing work bodies manually.
- Changing how `shift_time_edits` work with segmented shifts.
