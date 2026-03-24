# Manual Time Segments — Design Spec

**Date:** 2026-03-24
**Status:** Review

## Problem

When an admin modifies an employee's clock-in or clock-out time (adding time), there is no visibility into how much time was manually added vs. tracked by GPS. Admins also cannot add entirely new time blocks for scenarios like forgotten clock-ins or off-site training.

## Solution

Two features that share a common data model:

1. **Clock extension segments** — When editing clock-in/out adds time, a "Temps manuel ajouté" segment automatically appears in the timeline covering the delta.
2. **New manual shifts** — Admins can add a fully manual time block that appears as its own "Quart" in the approval timeline.

Both produce `manual_time` activities in the approval system with `needs_review` default status, mandatory reason, and full delete capability.

---

## Data Model

### New table: `manual_time_entries`

```sql
CREATE TABLE manual_time_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    date            DATE NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    reason          TEXT NOT NULL,
    -- Clock extension: links to the parent shift and the audit edit
    shift_id        UUID REFERENCES shifts(id) ON DELETE CASCADE,
    shift_time_edit_id UUID REFERENCES shift_time_edits(id) ON DELETE CASCADE,
    -- New manual shift: no shift_id, entry acts as its own shift container
    -- Optional project/location
    location_id     UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    UNIQUE(shift_time_edit_id)  -- one manual entry per clock edit
);
```

**Key distinction:**
- `shift_id IS NOT NULL` → clock extension (segment within existing quart)
- `shift_id IS NULL` → new manual quart (standalone)

### Schema changes to existing tables

**`activity_overrides.activity_type` CHECK constraint** — add `'manual_time'` to allowed values.

**`save_activity_override` and `remove_activity_override` RPCs** — add `'manual_time'` to the hardcoded `IF p_activity_type NOT IN (...)` validation whitelist. Without this, admins cannot approve/reject manual_time activities.

---

## RPCs

### 1. `add_manual_time`

Creates a new standalone manual time entry (new quart).

```
add_manual_time(
    p_employee_id  UUID,
    p_date         DATE,
    p_starts_at    TIMESTAMPTZ,
    p_ends_at      TIMESTAMPTZ,
    p_reason       TEXT,
    p_location_id  UUID DEFAULT NULL
) RETURNS JSONB  -- get_day_approval_detail result
```

**Validations:**
- Admin only
- Day not approved
- `p_reason` not empty
- `p_ends_at > p_starts_at`
- No overlap with existing shifts or other manual_time_entries of same employee on same day
- Date of `p_starts_at` must match `p_date` (business day)

**Behavior:**
1. Insert into `manual_time_entries` with `shift_id = NULL`
2. Return `get_day_approval_detail(p_employee_id, p_date)`

### 2. `delete_manual_time`

Deletes a manual time entry. For clock extensions, also reverts the clock edit.

```
delete_manual_time(
    p_manual_time_id  UUID
) RETURNS JSONB  -- get_day_approval_detail result
```

**Validations:**
- Admin only
- Day not approved
- Entry exists

**Behavior:**
1. If `shift_time_edit_id IS NOT NULL` (clock extension):
   - Look up the `shift_id` and `field` from the linked `shift_time_edits` row
   - Delete ALL `shift_time_edits` rows for that `(shift_id, field)` — fully reverts to the original clock time (not just the latest edit). This avoids orphaned intermediate edits that silently affect effective time.
   - Delete any `activity_overrides` for this manual_time entry
2. Delete the `manual_time_entries` row
3. Return `get_day_approval_detail(employee_id, date)`

### 3. Modify `edit_shift_time` (existing RPC)

When a clock edit **adds time** (new clock-out > old clock-out, or new clock-in < old clock-in):

**New parameter:** `p_reason TEXT` — becomes **mandatory** when time is added (validated server-side).

**New behavior after inserting shift_time_edit:**
1. Compute delta: `old_effective_time` vs `p_new_value`
2. If delta adds time (extends the shift):
   - Create `manual_time_entries` row with:
     - `shift_id` = the shift being edited
     - `shift_time_edit_id` = the just-inserted edit row
     - `starts_at` / `ends_at` = the delta range (old boundary → new boundary)
     - `reason` = `p_reason`
3. If delta removes time (shortens the shift):
   - No manual_time_entry created
   - Check if there's an existing manual_time_entry for a previous extension on this field — if so, delete it
4. **Overlap check**: validate that the new clock extension range does not overlap with any standalone `manual_time_entries` for this employee/date

### 4. Modify `_get_day_approval_detail_base` (existing RPC)

Add a new CTE for manual time entries:

```sql
manual_time_activities AS (
    SELECT
        'manual_time'::TEXT AS activity_type,
        mte.id AS activity_id,
        COALESCE(mte.shift_id, mte.id) AS shift_id,  -- own ID as shift_id for standalone
        mte.starts_at AS started_at,
        mte.ends_at AS ended_at,
        EXTRACT(EPOCH FROM (mte.ends_at - mte.starts_at))::INT / 60 AS duration_minutes,
        'needs_review'::TEXT AS auto_status,
        'Temps manuel ajouté'::TEXT AS auto_reason,
        mte.reason AS manual_reason,
        mte.location_id AS matched_location_id,
        l.name AS location_name,
        l.location_type,
        mte.shift_id IS NULL AS is_standalone_shift,
        mte.created_by,
        mte.created_at
    FROM manual_time_entries mte
    LEFT JOIN locations l ON l.id = mte.location_id
    WHERE mte.employee_id = p_employee_id
      AND mte.date = p_date
)
```

Include in the UNION ALL that builds the activities array. For standalone entries (`shift_id IS NULL`), use `mte.id` as `shift_id` so `groupDisplayItemsByShift` creates a separate quart container.

The JSONB object for each `manual_time` activity must include ALL fields from the `ApprovalActivity` type (set unused fields to NULL: `distance_km`, `road_distance_km`, `transport_mode`, `has_gps_gap`, `gps_gap_seconds`, `gps_gap_count`, etc.) to match the existing classified CTE pattern.

**Gap detection exclusion:** The gap detection CTEs (`activity_evts`, clock-in/out gaps) must exclude time ranges covered by `manual_time_entries`. Without this, a clock extension from 16:05→16:30 would produce both a `manual_time` segment AND a `gap` activity for the same period. Add a filter: `WHERE NOT EXISTS (SELECT 1 FROM manual_time_entries mte WHERE mte.employee_id = ... AND tsrange(mte.starts_at, mte.ends_at) && tsrange(gap_start, gap_end))`.

**`total_shift_minutes` for standalone entries:** The `v_total_shift_minutes` calculation sums from the `shifts` table via `effective_shift_times()`. Standalone manual entries have no `shifts` row, so they are excluded. Add:

```sql
v_total_shift_minutes := v_total_shift_minutes + COALESCE((
    SELECT SUM(EXTRACT(EPOCH FROM (ends_at - starts_at)) / 60)::INTEGER
    FROM manual_time_entries
    WHERE employee_id = p_employee_id AND date = p_date AND shift_id IS NULL
), 0);
```

**Clock extension double-count prevention:** For clock extensions (`shift_id IS NOT NULL`), the extended time is already counted in `total_shift_minutes` via the shift's effective duration. The `manual_time` activity's `duration_minutes` must NOT be added again to `approved_minutes`/`rejected_minutes` sums. Instead, clock extension `manual_time` activities have `duration_minutes = 0` for summary purposes — they exist purely as visual markers in the timeline. The actual time accounting flows through the shift's effective duration. Only standalone entries (`shift_id IS NULL`) contribute their `duration_minutes` to the approval sums.

### 5. Modify `approve_day` / `reopen_day`

- `approve_day`: include manual_time minutes in frozen totals
- `reopen_day`: no change needed (overrides already cleared)

---

## UI Changes

### Dashboard — `day-approval-detail.tsx`

**Header area:**
- Add "+ Temps manuel" button next to "Approuver la journée"
- Button opens a dialog/modal (not a popover — the form is too large)
- Hidden when day is approved

**New component: `AddManualTimeModal`**

Fields:
- Start time (time input)
- End time (time input)
- Duration preview (computed, read-only)
- Reason (textarea, mandatory, min 1 char trimmed)
- Project/Location (select, optional — populated from employee's known locations)

Actions:
- "Annuler" — closes modal
- "Ajouter le temps" — calls `add_manual_time` RPC, refreshes detail on success

### Dashboard — `clock-time-edit-popover.tsx`

When the new time **extends** the shift (adds time):
- Show info banner: "✏️ +{N} min seront ajoutées comme « Temps manuel »"
- Reason field becomes mandatory (disable submit if empty)
- Pass reason to `edit_shift_time` RPC

When the new time **shortens** the shift:
- No banner
- Reason remains optional (existing behavior)

### Dashboard — `approval-rows.tsx`

**New activity type rendering for `manual_time`:**
- Icon: `Pencil` (lucide)
- Background: `bg-amber-50` (yellow tint)
- Badge: `MANUEL` pill (amber, small, next to activity name)
- Label: "Temps manuel ajouté"
- Sub-line: `📝 "{reason}" — par {admin_name}, {date}`
- Location line (if set): `📍 {location_name}`
- Delete button: `✕` small button, calls `delete_manual_time`, with confirmation toast

**Standalone quart container:**
- Shift header gets amber border and `MANUEL` badge
- Delete button on the shift header ("Supprimer le quart")

### Dashboard — `merge-clock-events.ts`

`mergeClockEvents` must NOT merge clock events into `manual_time` activities. Clock extensions sit at shift boundaries (exactly where clock events are) and could fall within the 60-second merge tolerance. Add `manual_time` to the exclusion check so clock-in/out icons don't end up on the wrong row.

### Dashboard — `approval-utils.ts`

- `nestLunchActivities`: add `'manual_time'` to the exclusion list (alongside `stop_segment`, `trip_segment`, `gap_segment`) — manual time must never be absorbed into lunch groups
- `mergeSameLocationGaps`: `manual_time` activities should NOT be merged
- `groupDisplayItemsByShift`: standalone manual entries use `mte.id` as shift_id — disable `handleShiftTypeToggle` for these quarts (no real shift to toggle)

### TypeScript types

Add `'manual_time'` to:
- `ApprovalActivity.activity_type` in `dashboard/src/types/mileage.ts`
- `MergeableActivity.activity_type` in `dashboard/src/lib/utils/merge-clock-events.ts`

Add fields:
```typescript
manual_reason?: string;       // the admin's reason text
is_standalone_shift?: boolean; // true for new manual quarts
manual_created_by?: string;    // admin name for display
manual_created_at?: string;    // creation timestamp
```

---

## Summary Calculations

**Standalone quarts (`shift_id IS NULL`):**
- Added to `total_shift_minutes` (explicit sum, see RPC section)
- Their `duration_minutes` contributes to `approved_minutes` / `rejected_minutes` / `needs_review_count` based on `final_status`

**Clock extensions (`shift_id IS NOT NULL`):**
- Already counted in `total_shift_minutes` via `effective_shift_times()` on the parent shift
- `duration_minutes = 0` for summary calculation purposes (visual marker only, no double-count)
- The parent shift's existing activities (stops, trips, gaps) are what get approved/rejected — the manual_time row controls whether the extension time appears as `needs_review`

**Répartition badges:** New `✏️ Manuel` badge showing total manual time (sum of standalone durations + display-only duration of clock extensions for the badge only)

---

## Deletion Behavior

| Type | Delete action | Effect |
|------|--------------|--------|
| Clock extension | Delete manual_time_entry | Reverts clock edit + removes segment + removes any override |
| Standalone quart | Delete manual_time_entry | Removes entire quart + removes any override |

Both deletions are **permanent** — no audit trail (per user requirement).

---

## Edge Cases

1. **Admin edits clock-out, then edits again** — The first manual_time_entry is deleted (via `shift_time_edit_id` cascade or explicit cleanup), replaced by new one matching the new delta.
2. **Admin edits clock-in earlier, then later** — Same as above, delta recalculated.
3. **Admin shortens clock-out after extending it** — The manual_time_entry is deleted, no new one created.
4. **Overlap with existing manual quart and real shift** — Validated: `add_manual_time` checks for overlaps.
5. **Day approved with manual time** — Manual time frozen in approved/rejected totals. Cannot delete while approved (must reopen first).
6. **Clock extension on clock-in** — Segment appears at the START of the quart (before the first GPS activity): `new_clock_in → old_clock_in`.

---

## RLS Policies

```sql
-- manual_time_entries: admin read/write, employee read own
ALTER TABLE manual_time_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins full access" ON manual_time_entries
    FOR ALL USING (
        EXISTS (SELECT 1 FROM employee_profiles WHERE id = auth.uid() AND role IN ('admin', 'super_admin'))
    );

CREATE POLICY "Employees read own" ON manual_time_entries
    FOR SELECT USING (employee_id = auth.uid());
```

---

## COMMENT ON (schema context)

```sql
COMMENT ON TABLE manual_time_entries IS
'ROLE: Stores manually-added time segments created by admins.
STATUTS: Active row = visible in approval timeline. Deletion = permanent removal.
REGLES: Two modes: (1) shift_id NOT NULL = clock extension segment within existing shift,
(2) shift_id NULL = standalone manual shift (own quart container).
Reason is always mandatory. Default approval status is needs_review.
RELATIONS: employee_profiles (employee), shifts (optional parent), shift_time_edits (optional audit link), locations (optional project).
TRIGGERS: None.';
```
