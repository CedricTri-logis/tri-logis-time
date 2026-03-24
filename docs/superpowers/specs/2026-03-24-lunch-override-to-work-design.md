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

### 1. Remove lunch block in `save_activity_override` + add `lunch_segment` to type whitelists

**File:** New migration (will `CREATE OR REPLACE` both RPCs)

Remove the early-exit check in `save_activity_override`:
```sql
-- REMOVE THIS:
IF p_activity_type = 'lunch' THEN
    RAISE EXCEPTION 'Lunch activities cannot be overridden';
END IF;
```

Add `'lunch_segment'` to the type whitelist in **both** `save_activity_override` and `remove_activity_override`:
```sql
-- In both RPCs, update the type validation:
IF p_activity_type NOT IN (
    'trip', 'stop', 'clock_in', 'clock_out', 'gap',
    'lunch_start', 'lunch_end', 'lunch',
    'stop_segment', 'trip_segment', 'gap_segment',
    'lunch_segment'  -- NEW
) THEN
    RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
END IF;
```

### 2. Update CHECK constraints

**`activity_overrides`** — add `'lunch_segment'`:
```sql
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN (
      'trip', 'stop', 'clock_in', 'clock_out', 'gap',
      'lunch_start', 'lunch_end', 'lunch',
      'stop_segment', 'trip_segment', 'gap_segment',
      'lunch_segment'
    ));
```

**`activity_segments`** — add `'lunch'` (currently only allows `stop`, `trip`, `gap`):
```sql
ALTER TABLE activity_segments
    DROP CONSTRAINT IF EXISTS activity_segments_activity_type_check;
ALTER TABLE activity_segments
    ADD CONSTRAINT activity_segments_activity_type_check
    CHECK (activity_type IN ('stop', 'trip', 'gap', 'lunch'));
```

Without the `activity_segments` constraint update, `INSERT INTO activity_segments` with `activity_type = 'lunch'` will fail.

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

Segment type becomes `'lunch_segment'`. Rows created in `activity_segments` with `activity_type = 'lunch'`. No extra params needed (unlike `gap` which requires `p_employee_id`, `p_starts_at`, `p_ends_at`).

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
      -- Exclude parent lunch when segments exist
      AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'lunch')
)
```

When a lunch has `override_status = 'approved'`, its `final_status` becomes `'approved'`.

### 6. Add lunch segments CTE in `get_day_approval_detail`

Add a `lunch_segments` CTE (parallel to `stop_segments`, `trip_segments`):

```sql
lunch_segments AS (
    SELECT
        'lunch_segment'::TEXT AS activity_type,
        aseg.id AS activity_id,
        s.id AS shift_id,
        aseg.starts_at AS started_at,
        aseg.ends_at AS ended_at,
        (EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60)::INTEGER AS duration_minutes,
        'rejected'::TEXT AS auto_status,
        'Pause dîner (non payée)'::TEXT AS auto_reason,
        ao.override_status,
        COALESCE(ao.override_status, 'rejected') AS final_status,
        aseg.segment_index,
        ...
    FROM activity_segments aseg
    JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
    LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao
        ON ao.day_approval_id = da.id
        AND ao.activity_type = 'lunch_segment'
        AND ao.activity_id = aseg.id
    WHERE aseg.activity_type = 'lunch'
      AND aseg.employee_id = p_employee_id
      AND aseg.starts_at >= p_date::TIMESTAMPTZ
      AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
)
```

Include lunch_segments in the combined activities UNION.

### 7. Update summary calculations

**Current state** (line 1379-1382 of universal_activity_segments migration):
```sql
-- approved_minutes: excludes lunch, gap, gap_segment
COALESCE(SUM(...) FILTER (WHERE a->>'final_status' = 'approved'
    AND a->>'activity_type' NOT IN ('lunch', 'gap', 'gap_segment')), 0),
-- rejected_minutes: excludes gap, gap_segment, lunch
COALESCE(SUM(...) FILTER (WHERE a->>'final_status' = 'rejected'
    AND a->>'activity_type' NOT IN ('gap', 'gap_segment', 'lunch')), 0),
-- needs_review_count: excludes clock_in, clock_out, lunch
COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
    AND a->>'activity_type' NOT IN ('clock_in', 'clock_out', 'lunch'))
```

**New:** Remove `'lunch'` from the approved/rejected exclusion lists. Add `'lunch_segment'` to needs_review exclusion (lunch segments default to rejected, not needs_review — they should not block day approval):

```sql
-- approved_minutes: now includes approved lunch/lunch_segment
COALESCE(SUM(...) FILTER (WHERE a->>'final_status' = 'approved'
    AND a->>'activity_type' NOT IN ('gap', 'gap_segment')), 0),
-- rejected_minutes: now includes rejected lunch/lunch_segment
COALESCE(SUM(...) FILTER (WHERE a->>'final_status' = 'rejected'
    AND a->>'activity_type' NOT IN ('gap', 'gap_segment')), 0),
-- needs_review_count: lunch and lunch_segment excluded (they default to rejected, not needs_review)
COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
    AND a->>'activity_type' NOT IN ('clock_in', 'clock_out', 'lunch', 'lunch_segment'))
```

**Update `v_lunch_minutes`** to only count non-overridden lunch time:

For **non-segmented** lunches:
```sql
SELECT COALESCE(SUM(
    EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
)::INTEGER, 0)
INTO v_lunch_minutes
FROM shifts s
LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
    AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
    AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
WHERE s.employee_id = p_employee_id
  AND s.is_lunch = true
  AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
  AND s.clocked_out_at IS NOT NULL
  -- Exclude fully approved lunches
  AND COALESCE(ao.override_status, 'rejected') != 'approved'
  -- Exclude segmented lunches (handled separately)
  AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'lunch');
```

For **segmented** lunches, add non-approved segment durations:
```sql
v_lunch_minutes := v_lunch_minutes + COALESCE((
    SELECT SUM(
        EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60
    )::INTEGER
    FROM activity_segments aseg
    JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
    LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'lunch_segment' AND ao.activity_id = aseg.id
    WHERE aseg.activity_type = 'lunch'
      AND aseg.employee_id = p_employee_id
      AND (aseg.starts_at AT TIME ZONE 'America/Montreal')::date = p_date
      AND COALESCE(ao.override_status, 'rejected') != 'approved'
), 0);
```

### 8. Update weekly summary `day_lunch` CTE

The `day_lunch` CTE in `get_week_approval_summary` (line 1461) must also account for overrides, so the weekly view matches the day detail:

```sql
day_lunch AS (
    SELECT
        s.employee_id,
        (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date AS lunch_date,
        COALESCE(SUM(
            CASE
                -- Segmented: sum non-approved segment durations
                WHEN EXISTS (SELECT 1 FROM activity_segments aseg WHERE aseg.activity_type = 'lunch' AND aseg.activity_id = s.id) THEN 0
                -- Non-segmented: full duration if not approved
                WHEN COALESCE(ao.override_status, 'rejected') != 'approved' THEN
                    EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
                ELSE 0
            END
        ), 0) AS lunch_minutes
    FROM shifts s
    LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
        AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
    WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
      AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date BETWEEN p_week_start AND v_week_end
      AND s.employee_id IN (SELECT employee_id FROM employee_list)
    GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
)
```

Note: Segmented lunch minute calculation in the weekly summary can be a follow-up if needed — the weekly view is a display metric, not used for payroll.

## Dashboard UI Changes

### 9. `LunchGroupRow` — add approve + split buttons

Add an approve button (green checkmark) to the lunch row. When clicked, calls `save_activity_override` with `activity_type = 'lunch'`, `status = 'approved'`.

When the lunch is approved (overridden to work):
- Change the row's left border from slate to green
- Show a badge: "Converti en travail"
- The utensils icon can remain for context
- Keep the `LunchGroupRow` container — children remain nested for visual context (their status is irrelevant since the parent lunch override determines the minutes)

Also add a scissors button to allow splitting, which opens the existing `ActivitySegmentModal`.

When un-overriding (removing the approved override), the row reverts to default slate styling.

### 10. `ActivitySegmentModal` — support lunch type

Update the component's TypeScript prop type:
```typescript
activityType: 'stop' | 'trip' | 'gap' | 'lunch'
```

Add to `TITLE_MAP`:
```typescript
lunch: 'Diviser la pause dîner'
```

No extra params needed for lunch (unlike gap). The RPC resolves bounds from the `shifts` table using `p_activity_id`.

### 11. Lunch segment rows

Render `lunch_segment` activities similarly to `stop_segment` rows — with approve buttons and the segment indicator. Each segment can be independently approved (= work) or left as-is (= lunch, default).

### 12. TypeScript type updates

In `dashboard/src/types/mileage.ts`, add `'lunch_segment'` to `ApprovalActivity.activity_type`:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'lunch_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```

### 13. `nestLunchActivities` — skip nesting for approved lunches

In `approval-utils.ts`, the `nestLunchActivities` function should skip nesting for lunches with `final_status = 'approved'`. An approved lunch is "work" — it doesn't make sense to nest activities inside it. Those child activities will appear as regular timeline items instead.

For segmented lunches, nesting is also skipped since the parent lunch row is replaced by individual segment rows.

## No Flutter Changes

This is purely a supervisor dashboard action. The mobile app doesn't need changes.

## Edge Cases

- **Approved day**: Segmenting or overriding lunch requires reopening the day first (existing guard in `segment_activity` and `save_activity_override`).
- **Lunch with children (approved)**: When a lunch is approved as work, `nestLunchActivities` skips nesting — child activities appear as regular timeline items. Their auto_status from SQL is still `'rejected'` with reason `'Pendant la pause dîner'`, but since they're no longer nested under a lunch, they become independently reviewable.
- **Frozen totals**: The `approve_day` RPC already freezes `approved_minutes`. When a day with lunch overrides is approved, the frozen totals will include the converted lunch minutes.
- **Partial split**: If a 30-min lunch is split into two 15-min segments, approving one segment adds 15 min to work and removes 15 min from `lunch_minutes`.
- **`needs_review_count`**: Lunch and lunch_segment are excluded from `needs_review_count` — they default to `rejected` (not `needs_review`), so they never block day approval. Supervisors opt-in to converting them.

## Testing

- Override a full lunch → verify `approved_minutes` increases by lunch duration, `lunch_minutes` decreases to 0
- Split lunch into 2 segments, approve one → verify only that segment's minutes are added to `approved_minutes`
- Unsegment lunch → verify it reverts to default (rejected/lunch)
- Approve day with lunch override → verify frozen totals are correct
- Reopen day, remove lunch override → verify minutes revert
- Weekly summary → verify `lunch_minutes` matches day detail for overridden lunches
- Approved lunch nesting → verify child activities appear as standalone items in timeline
