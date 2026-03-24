# Lunch Override to Work — Design Spec

**Date:** 2026-03-24
**Status:** Draft
**Branch:** `feature/universal-activity-splitting`

## Problem

Lunch breaks are sometimes recorded by mistake — the employee didn't actually take a break, or only part of the recorded lunch was a real break. Supervisors need a way to recover that time as work.

Currently, lunch activities are hardcoded as non-overridable (`save_activity_override` raises an exception for `activity_type = 'lunch'`). There is no mechanism to convert lunch time to work time.

## Solution

Extend the existing override and segmentation system to support lunch activities:

- **Approve a lunch** = "this was actually work" → minutes count as work
- **No override (default)** = lunch stays as non-paid time (current behavior)
- **Split a lunch** = divide into segments, approve only the portions that were work

This follows the same mental model as other activities: lunch defaults to "rejected" (non-counted), and approving it overrides that to "work."

## Database Changes

### 1. Remove lunch block in `save_activity_override`

**File:** New migration (will `CREATE OR REPLACE` the function)

Remove the early-exit check:
```sql
-- REMOVE THIS:
IF p_activity_type = 'lunch' THEN
    RAISE EXCEPTION 'Lunch activities cannot be overridden';
END IF;
```

Allow `'lunch'` and `'lunch_segment'` as valid activity types.

### 2. Update `activity_overrides` CHECK constraint

Add `'lunch_segment'` to the allowed `activity_type` values:
```sql
CHECK (activity_type IN (
  'trip', 'stop', 'clock_in', 'clock_out', 'gap',
  'lunch_start', 'lunch_end', 'lunch',
  'stop_segment', 'trip_segment', 'gap_segment',
  'lunch_segment'  -- NEW
))
```

### 3. Extend `segment_activity` RPC to support lunch

Add `'lunch'` to the valid activity types. For lunch, resolve bounds from the `shifts` table:

```sql
ELSIF p_activity_type = 'lunch' THEN
    SELECT employee_id, clocked_in_at, clocked_out_at
    INTO v_employee_id, v_started_at, v_ended_at
    FROM shifts WHERE id = p_activity_id AND is_lunch = true;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Lunch shift not found';
    END IF;
```

Segment type becomes `'lunch_segment'`. Rows created in `activity_segments` with `activity_type = 'lunch'`.

### 4. Extend `unsegment_activity` to support lunch

Same pattern — add `'lunch'` to the valid types, resolve from `shifts` table.

### 5. Update `get_day_approval_detail` — lunch override logic

In the `lunch_data` CTE, instead of hardcoding `final_status = 'rejected'`, check for overrides:

```sql
lunch_data AS (
    SELECT
        'lunch'::TEXT AS activity_type,
        s.id AS activity_id,
        ...
        'rejected'::TEXT AS auto_status,
        'Pause dîner (non payée)'::TEXT AS auto_reason,
        ao.override_status,
        NULL::TEXT AS override_reason,
        COALESCE(ao.override_status, 'rejected') AS final_status,
        ...
    FROM shifts s
    LEFT JOIN day_approvals da
        ON da.employee_id = s.employee_id
        AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    LEFT JOIN activity_overrides ao
        ON ao.day_approval_id = da.id
        AND ao.activity_type = 'lunch'
        AND ao.activity_id = s.id
    WHERE ...
)
```

When a lunch has `override_status = 'approved'`, its `final_status` becomes `'approved'`.

### 6. Update lunch segment rendering in `get_day_approval_detail`

Add a `lunch_segments` CTE (parallel to `stop_segments`, `trip_segments`), which:
- Reads `activity_segments WHERE activity_type = 'lunch'`
- Joins `activity_overrides` for per-segment override status
- Returns rows with `activity_type = 'lunch_segment'`

Unsegmented lunch rows are excluded when segments exist (same pattern as stops/trips).

### 7. Update summary calculations

In the summary computation section, update the approved/rejected minute filters:

**Current:** Lunch is always excluded from approved_minutes:
```sql
WHERE a->>'final_status' = 'approved' AND a->>'activity_type' NOT IN ('lunch', 'gap', 'gap_segment')
```

**New:** Include lunch/lunch_segment when approved:
```sql
WHERE a->>'final_status' = 'approved' AND a->>'activity_type' NOT IN ('gap', 'gap_segment')
```

Also update `v_lunch_minutes` to only count non-overridden lunch time:
```sql
-- Lunch minutes = total lunch minus any approved (converted to work) lunch
SELECT COALESCE(SUM(...), 0)
INTO v_lunch_minutes
FROM shifts s
LEFT JOIN day_approvals da ON ...
LEFT JOIN activity_overrides ao ON ... AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
WHERE s.is_lunch = true
  AND s.clocked_out_at IS NOT NULL
  AND COALESCE(ao.override_status, 'rejected') != 'approved';
```

For segmented lunches, sum only non-approved segment durations.

## Dashboard UI Changes

### 8. `LunchGroupRow` — add approve button

Add an approve button (green checkmark) to the lunch row. When clicked, calls `save_activity_override` with `status = 'approved'`.

When the lunch is approved (overridden to work):
- Change the row's left border from slate to green
- Show a badge: "Converti en travail" or similar
- The utensils icon can remain for context

Also add a scissors button to allow splitting, which opens the existing `ActivitySegmentModal`.

### 9. `ActivitySegmentModal` — support lunch type

The modal already works for stops/trips/gaps. Extend it to accept `activity_type = 'lunch'` and call `segment_activity` with the lunch shift's bounds.

### 10. Lunch segment rows

Render `lunch_segment` activities similarly to `stop_segment` rows — with approve/reject buttons and the segment indicator. Each segment can be independently approved (= work) or left as-is (= lunch).

## No Flutter Changes

This is purely a supervisor dashboard action. The mobile app doesn't need changes.

## Edge Cases

- **Approved day**: Segmenting or overriding lunch requires reopening the day first (existing guard in `segment_activity` and `save_activity_override`).
- **Lunch with children**: When a lunch is approved as work, its nested child activities (stops/trips during lunch) should also become visible as regular activities. The `nestLunchActivities` utility should skip nesting for approved lunches.
- **Frozen totals**: The `approve_day` RPC already freezes `approved_minutes`. When a day with lunch overrides is approved, the frozen totals will include the converted lunch minutes.
- **Partial split**: If a 30-min lunch is split into two 15-min segments, approving one segment adds 15 min to work and removes 15 min from lunch_minutes.

## Testing

- Override a full lunch → verify `approved_minutes` increases by lunch duration, `lunch_minutes` decreases
- Split lunch into 2 segments, approve one → verify only that segment's minutes are added
- Unsegment lunch → verify it reverts to default (rejected/lunch)
- Approve day with lunch override → verify frozen totals are correct
- Reopen day, remove lunch override → verify minutes revert
