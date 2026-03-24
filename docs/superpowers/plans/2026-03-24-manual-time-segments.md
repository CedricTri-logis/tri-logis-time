# Manual Time Segments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow admins to add manual time entries (clock extensions + standalone shifts) with full visibility in the approval timeline.

**Architecture:** New `manual_time_entries` table stores both clock extensions (linked to a shift) and standalone manual quarts. The `_get_day_approval_detail_base` RPC includes them as `manual_time` activities. Frontend renders them with distinct amber styling and MANUEL badge.

**Tech Stack:** PostgreSQL (Supabase migration), TypeScript/Next.js (dashboard), shadcn/ui

**Spec:** `docs/superpowers/specs/2026-03-24-manual-time-segments-design.md`

---

### Task 1: Database — Create `manual_time_entries` table and update constraints

**Files:**
- Create: `supabase/migrations/20260327200000_manual_time_entries.sql`

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================================
-- Manual Time Entries table + RLS + constraint updates
-- ============================================================================

-- Table
CREATE TABLE manual_time_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    date            DATE NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    reason          TEXT NOT NULL,
    shift_id        UUID REFERENCES shifts(id) ON DELETE CASCADE,
    shift_time_edit_id UUID REFERENCES shift_time_edits(id) ON DELETE CASCADE,
    location_id     UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    UNIQUE(shift_time_edit_id)
);

CREATE INDEX idx_manual_time_entries_employee_date ON manual_time_entries(employee_id, date);
CREATE INDEX idx_manual_time_entries_shift ON manual_time_entries(shift_id) WHERE shift_id IS NOT NULL;

-- RLS
ALTER TABLE manual_time_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins full access" ON manual_time_entries
    FOR ALL USING (
        EXISTS (SELECT 1 FROM employee_profiles WHERE id = auth.uid() AND role IN ('admin', 'super_admin'))
    );

CREATE POLICY "Employees read own" ON manual_time_entries
    FOR SELECT USING (employee_id = auth.uid());

-- Schema context
COMMENT ON TABLE manual_time_entries IS
'ROLE: Stores manually-added time segments created by admins.
STATUTS: Active row = visible in approval timeline. Deletion = permanent removal.
REGLES: Two modes: (1) shift_id NOT NULL = clock extension segment within existing shift,
(2) shift_id NULL = standalone manual shift (own quart container).
Reason is always mandatory. Default approval status is needs_review.
RELATIONS: employee_profiles (employee), shifts (optional parent), shift_time_edits (optional audit link), locations (optional project).
TRIGGERS: None.';

COMMENT ON COLUMN manual_time_entries.shift_id IS 'When NOT NULL: clock extension attached to this shift. When NULL: standalone manual quart.';
COMMENT ON COLUMN manual_time_entries.shift_time_edit_id IS 'Links to the shift_time_edits audit row that triggered this manual entry (clock extensions only).';

-- Update activity_overrides CHECK constraint to allow 'manual_time'
ALTER TABLE activity_overrides DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment', 'manual_time'
    ));
```

- [ ] **Step 2: Apply the migration**

Run: `supabase migration up` or apply via MCP `apply_migration`

- [ ] **Step 3: Verify table exists**

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'manual_time_entries'
ORDER BY ordinal_position;
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260327200000_manual_time_entries.sql
git commit -m "feat: create manual_time_entries table with RLS"
```

---

### Task 2: Database — `add_manual_time` and `delete_manual_time` RPCs

**Files:**
- Create: `supabase/migrations/20260327200001_manual_time_rpcs.sql`

- [ ] **Step 1: Write the RPCs**

```sql
-- ============================================================================
-- add_manual_time: create a standalone manual time entry (new quart)
-- ============================================================================
CREATE OR REPLACE FUNCTION add_manual_time(
    p_employee_id UUID,
    p_date DATE,
    p_starts_at TIMESTAMPTZ,
    p_ends_at TIMESTAMPTZ,
    p_reason TEXT,
    p_location_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can add manual time';
    END IF;

    -- Validate reason
    IF TRIM(COALESCE(p_reason, '')) = '' THEN
        RAISE EXCEPTION 'Reason is mandatory for manual time entries';
    END IF;

    -- Validate times
    IF p_ends_at <= p_starts_at THEN
        RAISE EXCEPTION 'End time must be after start time';
    END IF;

    -- Validate date
    IF to_business_date(p_starts_at) != p_date THEN
        RAISE EXCEPTION 'Start time does not match the specified date';
    END IF;

    -- Day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before adding manual time.';
    END IF;

    -- Overlap with shifts
    IF EXISTS (
        SELECT 1
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
        AND s.clocked_in_at::DATE = p_date
        AND s.status = 'completed'
        AND NOT s.is_lunch
        AND est.effective_clocked_out_at IS NOT NULL
        AND tstzrange(est.effective_clocked_in_at, est.effective_clocked_out_at) &&
            tstzrange(p_starts_at, p_ends_at)
    ) THEN
        RAISE EXCEPTION 'Manual time overlaps with an existing shift';
    END IF;

    -- Overlap with other manual entries
    IF EXISTS (
        SELECT 1 FROM manual_time_entries
        WHERE employee_id = p_employee_id AND date = p_date
        AND tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, p_ends_at)
    ) THEN
        RAISE EXCEPTION 'Manual time overlaps with another manual entry';
    END IF;

    -- Insert
    INSERT INTO manual_time_entries (employee_id, date, starts_at, ends_at, reason, location_id, created_by)
    VALUES (p_employee_id, p_date, p_starts_at, p_ends_at, p_reason, p_location_id, v_caller);

    -- Return updated detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================================
-- delete_manual_time: remove a manual entry, revert clock edits if extension
-- ============================================================================
CREATE OR REPLACE FUNCTION delete_manual_time(
    p_manual_time_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_entry RECORD;
    v_edit RECORD;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can delete manual time';
    END IF;

    -- Get entry
    SELECT * INTO v_entry FROM manual_time_entries WHERE id = p_manual_time_id;
    IF v_entry IS NULL THEN
        RAISE EXCEPTION 'Manual time entry not found';
    END IF;

    -- Day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_entry.employee_id AND date = v_entry.date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before deleting manual time.';
    END IF;

    -- If clock extension: revert ALL clock edits for that (shift_id, field)
    IF v_entry.shift_time_edit_id IS NOT NULL THEN
        SELECT shift_id, field INTO v_edit
        FROM shift_time_edits WHERE id = v_entry.shift_time_edit_id;

        IF v_edit IS NOT NULL THEN
            DELETE FROM shift_time_edits
            WHERE shift_id = v_edit.shift_id AND field = v_edit.field;
        END IF;
    END IF;

    -- Delete any overrides for this manual_time activity
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_entry.employee_id AND date = v_entry.date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'manual_time'
        AND activity_id = p_manual_time_id;
    END IF;

    -- Delete the entry
    DELETE FROM manual_time_entries WHERE id = p_manual_time_id;

    -- Return updated detail
    SELECT get_day_approval_detail(v_entry.employee_id, v_entry.date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 2: Apply and verify**

```sql
SELECT proname FROM pg_proc WHERE proname IN ('add_manual_time', 'delete_manual_time');
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260327200001_manual_time_rpcs.sql
git commit -m "feat: add add_manual_time and delete_manual_time RPCs"
```

---

### Task 3: Database — Modify `edit_shift_time` to auto-create manual entries

**Files:**
- Create: `supabase/migrations/20260327200002_edit_shift_time_manual_entry.sql`

- [ ] **Step 1: Write the updated RPC**

The updated `edit_shift_time` must, after inserting the audit row:
1. Compute whether the edit extends the shift (adds time)
2. If extending: delete any existing manual_time_entry for a previous extension on this (shift, field), then create a new one
3. If shortening: delete any existing manual_time_entry for this (shift, field)
4. Check overlap with standalone manual entries
5. Require reason when time is added

```sql
CREATE OR REPLACE FUNCTION edit_shift_time(
    p_shift_id UUID,
    p_field TEXT,
    p_new_value TIMESTAMPTZ,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_shift_record RECORD;
    v_effective RECORD;
    v_current_date DATE;
    v_new_date DATE;
    v_effective_in TIMESTAMPTZ;
    v_effective_out TIMESTAMPTZ;
    v_old_value TIMESTAMPTZ;
    v_extends_shift BOOLEAN := FALSE;
    v_delta_start TIMESTAMPTZ;
    v_delta_end TIMESTAMPTZ;
    v_edit_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can edit shift times';
    END IF;

    -- Validate field
    IF p_field NOT IN ('clocked_in_at', 'clocked_out_at') THEN
        RAISE EXCEPTION 'Field must be clocked_in_at or clocked_out_at';
    END IF;

    -- Get shift
    SELECT id, employee_id, clocked_in_at, clocked_out_at, status
    INTO v_shift_record
    FROM shifts
    WHERE id = p_shift_id;

    IF v_shift_record IS NULL THEN
        RAISE EXCEPTION 'Shift not found';
    END IF;

    v_employee_id := v_shift_record.employee_id;

    -- Cannot edit clock_out on active shift
    IF p_field = 'clocked_out_at' AND v_shift_record.status = 'active' THEN
        RAISE EXCEPTION 'Cannot edit clock-out on an active shift';
    END IF;

    -- Get current effective times
    SELECT * INTO v_effective FROM effective_shift_times(p_shift_id);
    v_current_date := to_business_date(v_effective.effective_clocked_in_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_current_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before editing shift times.';
    END IF;

    -- Date change guard (clocked_in_at only)
    IF p_field = 'clocked_in_at' THEN
        v_new_date := to_business_date(p_new_value);
        IF v_new_date != v_current_date THEN
            RAISE EXCEPTION 'Edit would move shift to a different day (% → %). Adjust to stay within the same calendar date.', v_current_date, v_new_date;
        END IF;
    END IF;

    -- Temporal consistency: clock_in < clock_out
    IF p_field = 'clocked_in_at' THEN
        v_effective_in := p_new_value;
        v_effective_out := v_effective.effective_clocked_out_at;
    ELSE
        v_effective_in := v_effective.effective_clocked_in_at;
        v_effective_out := p_new_value;
    END IF;

    IF v_effective_out IS NOT NULL AND v_effective_in >= v_effective_out THEN
        RAISE EXCEPTION 'Clock-in must be before clock-out';
    END IF;

    -- Overlap with other shifts
    IF EXISTS (
        SELECT 1
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = v_employee_id
        AND s.id != p_shift_id
        AND s.status = 'completed'
        AND est.effective_clocked_out_at IS NOT NULL
        AND tstzrange(est.effective_clocked_in_at, est.effective_clocked_out_at) &&
            tstzrange(v_effective_in, v_effective_out)
    ) THEN
        RAISE EXCEPTION 'Edited time would overlap with another shift';
    END IF;

    -- Determine old effective value and whether shift is extended
    IF p_field = 'clocked_in_at' THEN
        v_old_value := v_effective.effective_clocked_in_at;
        -- Extending = new clock-in is EARLIER than old
        v_extends_shift := (p_new_value < v_old_value);
        IF v_extends_shift THEN
            v_delta_start := p_new_value;
            v_delta_end := v_old_value;
        END IF;
    ELSE
        v_old_value := v_effective.effective_clocked_out_at;
        -- Extending = new clock-out is LATER than old
        v_extends_shift := (p_new_value > v_old_value);
        IF v_extends_shift THEN
            v_delta_start := v_old_value;
            v_delta_end := p_new_value;
        END IF;
    END IF;

    -- Reason mandatory when extending
    IF v_extends_shift AND TRIM(COALESCE(p_reason, '')) = '' THEN
        RAISE EXCEPTION 'Reason is mandatory when adding time to a shift';
    END IF;

    -- Overlap check with standalone manual entries (only when extending)
    IF v_extends_shift AND EXISTS (
        SELECT 1 FROM manual_time_entries
        WHERE employee_id = v_employee_id AND date = v_current_date
        AND shift_id IS NULL
        AND tstzrange(starts_at, ends_at) && tstzrange(v_delta_start, v_delta_end)
    ) THEN
        RAISE EXCEPTION 'Clock extension would overlap with a manual time entry';
    END IF;

    -- Insert audit row
    INSERT INTO shift_time_edits (shift_id, field, old_value, new_value, reason, changed_by)
    VALUES (p_shift_id, p_field, v_old_value, p_new_value, p_reason, v_caller)
    RETURNING id INTO v_edit_id;

    -- Delete any existing manual_time_entry for previous extension on this (shift, field)
    DELETE FROM manual_time_entries
    WHERE shift_id = p_shift_id
    AND shift_time_edit_id IN (
        SELECT id FROM shift_time_edits
        WHERE shift_id = p_shift_id AND field = p_field AND id != v_edit_id
    );

    -- Create manual_time_entry if extending
    IF v_extends_shift THEN
        INSERT INTO manual_time_entries (employee_id, date, starts_at, ends_at, reason, shift_id, shift_time_edit_id, created_by)
        VALUES (v_employee_id, v_current_date, v_delta_start, v_delta_end, p_reason, p_shift_id, v_edit_id, v_caller);
    END IF;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_current_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 2: Apply and test**

Test by calling `edit_shift_time` with a clock-out that extends a shift, verify a `manual_time_entries` row is created.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260327200002_edit_shift_time_manual_entry.sql
git commit -m "feat: edit_shift_time auto-creates manual_time_entries on extension"
```

---

### Task 4: Database — Update `_get_day_approval_detail_base` to include manual_time

**Files:**
- Create: `supabase/migrations/20260327200003_detail_include_manual_time.sql`

This is the most complex migration. It must:
1. Add `manual_time_activities` CTE to the UNION ALL
2. Add standalone entries to `v_total_shift_minutes`
3. Exclude manual_time ranges from gap detection
4. Set `duration_minutes = 0` for clock extensions in summary calculations
5. Add `'manual_time'` to override RPCs
6. Include all JSONB fields for type compatibility

- [ ] **Step 1: Read the current `_get_day_approval_detail_base`**

Read `supabase/migrations/20260312500003_approval_detail_time_corrections.sql` fully to understand the CTE structure and identify exact insertion points.

- [ ] **Step 2: Write the migration**

The migration must `CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(...)` with the manual_time CTE added. Key changes:

1. After `v_total_shift_minutes` calculation from shifts, add:
```sql
-- Add standalone manual entries to total
v_total_shift_minutes := v_total_shift_minutes + COALESCE((
    SELECT SUM(EXTRACT(EPOCH FROM (ends_at - starts_at)) / 60)::INTEGER
    FROM manual_time_entries
    WHERE employee_id = p_employee_id AND date = p_date AND shift_id IS NULL
), 0);
```

2. Add `manual_time_data` CTE (includes override join for approve/reject support):
```sql
manual_time_data AS (
    SELECT
        'manual_time'::TEXT AS activity_type,
        mte.id AS activity_id,
        COALESCE(mte.shift_id, mte.id) AS shift_id,
        mte.starts_at AS started_at,
        mte.ends_at AS ended_at,
        CASE WHEN mte.shift_id IS NOT NULL THEN 0
             ELSE EXTRACT(EPOCH FROM (mte.ends_at - mte.starts_at))::INT / 60
        END AS duration_minutes,
        'needs_review'::TEXT AS auto_status,
        'Temps manuel ajouté'::TEXT AS auto_reason,
        ao.override_status,
        ao.reason AS override_reason,
        COALESCE(ao.override_status, 'needs_review') AS final_status,
        mte.reason AS manual_reason,
        mte.location_id AS matched_location_id,
        l.name AS location_name,
        l.location_type::TEXT,
        (mte.shift_id IS NULL) AS is_standalone_shift,
        mte.created_by,
        mte.created_at,
        ep.full_name AS manual_created_by_name
    FROM manual_time_entries mte
    LEFT JOIN locations l ON l.id = mte.location_id
    LEFT JOIN employee_profiles ep ON ep.id = mte.created_by
    LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'manual_time' AND ao.activity_id = mte.id
    WHERE mte.employee_id = p_employee_id
      AND mte.date = p_date
)
```

3. Include in UNION ALL with all required JSONB fields (NULL for unused ones).

4. In gap detection, add exclusion: `AND NOT EXISTS (SELECT 1 FROM manual_time_entries mte WHERE mte.employee_id = p_employee_id AND mte.date = p_date AND tstzrange(mte.starts_at, mte.ends_at) && tstzrange(gap_start, gap_end))`

5. Update `save_activity_override` and `remove_activity_override` to add `'manual_time'` to whitelist.

- [ ] **Step 3: Apply and test**

```sql
-- Test: verify manual_time appears in day detail for an employee with a manual entry
SELECT get_day_approval_detail('employee-uuid', '2026-03-09');
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260327200003_detail_include_manual_time.sql
git commit -m "feat: include manual_time in day approval detail + update override RPCs"
```

---

### Task 5: Frontend — TypeScript types

**Files:**
- Modify: `dashboard/src/types/mileage.ts:250` (ApprovalActivity.activity_type)
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts:9` (MergeableActivity.activity_type)

- [ ] **Step 1: Update `ApprovalActivity`**

In `dashboard/src/types/mileage.ts:250`, add `'manual_time'` to the activity_type union:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch' | 'manual_time';
```

Add new fields after line 281:
```typescript
manual_reason?: string;
is_standalone_shift?: boolean;
manual_created_by?: string;
manual_created_at?: string;
```

- [ ] **Step 2: Update `MergeableActivity`**

In `dashboard/src/lib/utils/merge-clock-events.ts:9`, add `'manual_time'`:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch' | 'manual_time';
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat: add manual_time to TypeScript activity types"
```

---

### Task 6: Frontend — Exclude `manual_time` from clock merging and lunch nesting

**Files:**
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts:76`
- Modify: `dashboard/src/components/approvals/approval-utils.ts:387-390`

- [ ] **Step 1: Exclude from clock merge targets**

In `merge-clock-events.ts:76`, the stop-matching loop currently checks:
```typescript
if (filtered[j].activity_type !== 'stop' && filtered[j].activity_type !== 'stop_segment' && filtered[j].activity_type !== 'gap') continue;
```
This already excludes `manual_time` (only allows stop/stop_segment/gap). No change needed here — `manual_time` will never be a merge target.

Verify this is correct by reading line 76 again. If the condition uses an allow-list (only stop/stop_segment/gap), `manual_time` is already excluded.

- [ ] **Step 2: Exclude from lunch nesting**

In `approval-utils.ts:387-390`, add `'manual_time'` to the exclusion:
```typescript
if (item.type === 'activity' && (
  item.pa.item.activity_type === 'stop_segment' ||
  item.pa.item.activity_type === 'trip_segment' ||
  item.pa.item.activity_type === 'gap_segment' ||
  item.pa.item.activity_type === 'manual_time'
)) return;
```

- [ ] **Step 3: Verify build**

Run: `cd dashboard && npx next build`

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-utils.ts
git commit -m "feat: exclude manual_time from lunch nesting"
```

---

### Task 7: Frontend — Manual time row rendering in `approval-rows.tsx`

**Files:**
- Modify: `dashboard/src/components/approvals/approval-rows.tsx:91-132` (ApprovalActivityIcon)
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` (ActivityRow — add manual_time display)

- [ ] **Step 1: Add icon for `manual_time`**

In `ApprovalActivityIcon`, add a case for `manual_time` before the existing checks (around line 91):
```typescript
import { Pencil } from 'lucide-react';

// Inside ApprovalActivityIcon:
if (activity.activity_type === 'manual_time') {
  return <Pencil className="h-4 w-4 text-amber-600" />;
}
```

- [ ] **Step 2: Add manual_time styling in ActivityRow**

In `ActivityRow`, add conditional styling for the row background and the MANUEL badge. The row should have `bg-amber-50` background and show:
- "Temps manuel ajouté" as the activity name
- A `MANUEL` amber pill badge
- The reason text below the name
- A delete button (✕) that calls `delete_manual_time`

Add these props to ActivityRow:
```typescript
onDeleteManualTime?: (manualTimeId: string) => void;
```

In the row rendering, check `activity.activity_type === 'manual_time'`:
- Add `bg-amber-50` to the row's className
- Show the MANUEL badge: `<span className="bg-amber-100 text-amber-800 px-1.5 py-0.5 rounded-full text-[10px] font-bold border border-amber-200">MANUEL</span>`
- Show reason: `<div className="text-[11px] text-amber-700 mt-0.5">📝 {activity.manual_reason} — par {activity.manual_created_by}</div>`
- Show location if present: `<div className="text-[11px] text-muted-foreground mt-0.5">📍 {activity.location_name}</div>`
- Show delete button if not approved day

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: render manual_time activities in approval timeline"
```

---

### Task 8: Frontend — Standalone quart header styling

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (shift container rendering)

- [ ] **Step 1: Detect manual quarts in shift grouping**

In `day-approval-detail.tsx`, where shift containers are rendered (the `shiftGroups.map(...)` loop), check if all activities in the group have `is_standalone_shift === true`. If so:
- Add amber border to the container: `border-2 border-amber-200`
- Add MANUEL badge in the shift header next to the quart label
- Add "Supprimer le quart" delete button in the header
- Disable the shift type toggle (no `handleShiftTypeToggle` for manual quarts)

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: amber styling for standalone manual quart containers"
```

---

### Task 9: Frontend — `AddManualTimeModal` component

**Files:**
- Create: `dashboard/src/components/approvals/add-manual-time-modal.tsx`

- [ ] **Step 1: Create the modal component**

```typescript
'use client';

import { useState } from 'react';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { createClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
import type { DayApprovalDetail } from '@/types/mileage';

interface AddManualTimeModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  employeeId: string;
  date: string; // YYYY-MM-DD
  onUpdated: (newDetail: DayApprovalDetail) => void;
}

export function AddManualTimeModal({ open, onOpenChange, employeeId, date, onUpdated }: AddManualTimeModalProps) {
  const [startTime, setStartTime] = useState('');
  const [endTime, setEndTime] = useState('');
  const [reason, setReason] = useState('');
  const [locationId, setLocationId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Compute duration
  const durationMinutes = (() => {
    if (!startTime || !endTime) return 0;
    const [sh, sm] = startTime.split(':').map(Number);
    const [eh, em] = endTime.split(':').map(Number);
    return (eh * 60 + em) - (sh * 60 + sm);
  })();

  const formatDur = (mins: number) => {
    if (mins <= 0) return '—';
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return h > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${m} min`;
  };

  const handleSubmit = async () => {
    if (!startTime || !endTime || !reason.trim()) return;
    setLoading(true);
    setError(null);

    const startsAt = new Date(`${date}T${startTime}:00`).toISOString();
    const endsAt = new Date(`${date}T${endTime}:00`).toISOString();

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc('add_manual_time', {
      p_employee_id: employeeId,
      p_date: date,
      p_starts_at: startsAt,
      p_ends_at: endsAt,
      p_reason: reason.trim(),
      p_location_id: locationId,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    toast.success('Temps manuel ajouté');
    setLoading(false);
    onOpenChange(false);
    setStartTime('');
    setEndTime('');
    setReason('');
    setLocationId(null);
    onUpdated(data as DayApprovalDetail);
  };

  const canSubmit = startTime && endTime && reason.trim() && durationMinutes > 0 && !loading;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            ✏️ Ajouter du temps manuel
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs font-semibold text-muted-foreground uppercase">Heure début</label>
              <input type="time" value={startTime} onChange={e => setStartTime(e.target.value)}
                className="w-full rounded-md border px-3 py-2 text-sm" />
            </div>
            <div>
              <label className="text-xs font-semibold text-muted-foreground uppercase">Heure fin</label>
              <input type="time" value={endTime} onChange={e => setEndTime(e.target.value)}
                className="w-full rounded-md border px-3 py-2 text-sm" />
            </div>
          </div>

          {durationMinutes > 0 && (
            <div className="bg-muted/50 rounded-lg px-3 py-2 flex items-center gap-2">
              <span className="text-xs text-muted-foreground">Durée:</span>
              <span className="text-sm font-bold">{formatDur(durationMinutes)}</span>
            </div>
          )}

          <div>
            <label className="text-xs font-semibold text-muted-foreground uppercase">
              Raison <span className="text-destructive">*</span>
            </label>
            <Textarea value={reason} onChange={e => setReason(e.target.value)}
              placeholder="Expliquez pourquoi ce temps est ajouté manuellement..."
              className="h-20 text-sm" />
          </div>

          {/* Location select - TODO: populate from employee's known locations */}

          {error && <div className="text-xs text-destructive">{error}</div>}

          <div className="flex gap-2 justify-end">
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={loading}>Annuler</Button>
            <Button onClick={handleSubmit} disabled={!canSubmit}
              className="bg-amber-800 hover:bg-amber-900">
              {loading ? 'Ajout...' : 'Ajouter le temps'}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/approvals/add-manual-time-modal.tsx
git commit -m "feat: AddManualTimeModal component"
```

---

### Task 10: Frontend — Integrate modal and delete actions in `day-approval-detail.tsx`

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

- [ ] **Step 1: Add state and handlers**

Import and wire up:
```typescript
import { AddManualTimeModal } from './add-manual-time-modal';
```

Add state:
```typescript
const [showAddManual, setShowAddManual] = useState(false);
```

Add delete handler:
```typescript
const handleDeleteManualTime = async (manualTimeId: string) => {
  const supabase = createClient();
  const { data, error } = await supabase.rpc('delete_manual_time', {
    p_manual_time_id: manualTimeId,
  });
  if (error) {
    toast.error(error.message);
    return;
  }
  hasChanges.current = true;
  setDetail(data as DayApprovalDetailType);
  toast.success('Temps manuel supprimé');
};
```

- [ ] **Step 2: Add button in header**

Next to the approve button area, add:
```typescript
{!isApproved && (
  <Button variant="outline" size="sm" onClick={() => setShowAddManual(true)}
    className="bg-amber-50 border-amber-200 text-amber-800 hover:bg-amber-100">
    ✏️ + Temps manuel
  </Button>
)}
```

- [ ] **Step 3: Add modal at bottom of component**

```typescript
<AddManualTimeModal
  open={showAddManual}
  onOpenChange={setShowAddManual}
  employeeId={employeeId}
  date={date}
  onUpdated={(d) => { setDetail(d); hasChanges.current = true; }}
/>
```

- [ ] **Step 4: Pass delete handler to ActivityRow**

Thread `onDeleteManualTime={handleDeleteManualTime}` through to `ActivityRow` for `manual_time` activities.

- [ ] **Step 5: Verify build**

Run: `cd dashboard && npx next build`

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: integrate AddManualTimeModal and delete actions in day detail"
```

---

### Task 11: Frontend — Update `clock-time-edit-popover.tsx` for mandatory reason

**Files:**
- Modify: `dashboard/src/components/approvals/clock-time-edit-popover.tsx`

- [ ] **Step 1: Add time extension detection**

Add props to detect if time is being extended:
```typescript
// Add to props:
effectiveClockIn?: string;   // current effective clock-in ISO
effectiveClockOut?: string;  // current effective clock-out ISO
```

Compute whether the edit extends the shift:
```typescript
const addsTime = (() => {
  if (!time) return false;
  const [h, m] = time.split(':').map(Number);
  const currentDate = new Date(currentTime);
  const newDate = new Date(currentDate);
  newDate.setHours(h, m, 0, 0);

  if (field === 'clocked_out_at') {
    const currentEffective = new Date(effectiveClockOut || currentTime);
    return newDate > currentEffective;
  } else {
    const currentEffective = new Date(effectiveClockIn || currentTime);
    return newDate < currentEffective;
  }
})();

const addedMinutes = (() => {
  if (!addsTime) return 0;
  const [h, m] = time.split(':').map(Number);
  const currentDate = new Date(currentTime);
  const newDate = new Date(currentDate);
  newDate.setHours(h, m, 0, 0);
  const effective = new Date(field === 'clocked_out_at' ? (effectiveClockOut || currentTime) : (effectiveClockIn || currentTime));
  return Math.abs(Math.round((newDate.getTime() - effective.getTime()) / 60000));
})();
```

- [ ] **Step 2: Add info banner and mandatory reason**

Before the reason textarea:
```typescript
{addsTime && addedMinutes > 0 && (
  <div className="bg-amber-50 border border-amber-200 rounded-md px-3 py-2 text-xs text-amber-800 flex items-center gap-1.5">
    ✏️ <strong>+{addedMinutes} min</strong> seront ajoutées comme « Temps manuel »
  </div>
)}
```

Update the label:
```typescript
<label className="text-xs text-muted-foreground">
  Raison {addsTime ? <span className="text-destructive">*</span> : '(optionnel)'}
</label>
```

Disable save when extending without reason:
```typescript
disabled={loading || (addsTime && !reason.trim())}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/approvals/clock-time-edit-popover.tsx
git commit -m "feat: mandatory reason and info banner on clock extension"
```

---

### Task 12: Frontend — Répartition badge for manual time

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (répartition badges section)

- [ ] **Step 1: Compute manual time total**

In the duration stats computation, add manual time calculation:
```typescript
const manualTimeSeconds = processedActivities
  .filter(pa => pa.item.activity_type === 'manual_time')
  .reduce((sum, pa) => {
    // Use actual time range for display, even if duration_minutes is 0 for clock extensions
    const start = new Date(pa.item.started_at).getTime();
    const end = new Date(pa.item.ended_at).getTime();
    return sum + (end - start) / 1000;
  }, 0);
```

- [ ] **Step 2: Add badge in répartition section**

After the call bonus badge, add:
```typescript
{manualTimeSeconds > 0 && (
  <span className="inline-flex items-center gap-1 rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700 border border-amber-100"
    title="Temps manuel ajouté">
    <Pencil className="h-3 w-3" />
    {formatDuration(manualTimeSeconds)}
  </span>
)}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add manual time badge in répartition section"
```

---

### Task 13: Frontend — Empty days clickable in approval grid

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx:165-173` (handleCellClick)
- Modify: `dashboard/src/components/approvals/approval-grid.tsx:31-37` (STATUS_COLORS)
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (empty state)

- [ ] **Step 1: Make `no_shift` cells clickable**

In `approval-grid.tsx:167`, the `handleCellClick` currently returns early for `no_shift`:
```typescript
if (!day || day.status === 'no_shift' || day.status === 'active') return;
```

Change to only block `active`:
```typescript
if (!day || day.status === 'active') return;
```

- [ ] **Step 2: Add hover/cursor style for `no_shift`**

In `STATUS_COLORS` (line 37), update `no_shift`:
```typescript
no_shift: 'bg-white text-gray-300 hover:bg-amber-50/50 cursor-pointer',
```

- [ ] **Step 3: Add empty state in `day-approval-detail.tsx`**

When `detail` has no activities and no loading state, show:
```typescript
{detail && detail.activities.length === 0 && (
  <div className="flex flex-col items-center justify-center py-16 gap-4 text-muted-foreground">
    <Clock className="h-10 w-10 text-muted-foreground/30" />
    <p className="text-sm">Aucun quart enregistré pour cette journée</p>
    <Button variant="outline" onClick={() => setShowAddManual(true)}
      className="bg-amber-50 border-amber-200 text-amber-800 hover:bg-amber-100">
      ✏️ + Ajouter du temps manuel
    </Button>
  </div>
)}
```

- [ ] **Step 4: Handle `no_shift` day in `get_day_approval_detail`**

Verify the RPC returns a valid response for days with no shifts. It should return:
- `activities: []`
- `summary: { total_shift_minutes: 0, ... }`
- `approval_status: 'pending'`

If it currently returns NULL or errors for `no_shift` days, the `add_manual_time` RPC handles the case independently (it only needs `employee_id` and `date`).

For `no_shift` days where `get_day_approval_detail` might not return data, add a fallback in the frontend:
```typescript
if (!data && !isLoading) {
  // Empty day - show empty state with manual time button
  setDetail({
    employee_id: employeeId,
    date,
    has_active_shift: false,
    approval_status: 'pending',
    approved_by: null,
    approved_at: null,
    notes: null,
    activities: [],
    project_sessions: [],
    summary: { total_shift_minutes: 0, approved_minutes: 0, rejected_minutes: 0, needs_review_count: 0, lunch_minutes: 0, call_count: 0, call_billed_minutes: 0, call_bonus_minutes: 0 },
  });
}
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: make empty days clickable for manual time entry"
```

---

### Task 14: Verification — End-to-end testing

- [ ] **Step 1: Test standalone manual quart**

1. Open day approval detail for an employee
2. Click "+ Temps manuel"
3. Enter start/end time, reason, submit
4. Verify: new Quart appears with amber border, MANUEL badge, reason shown
5. Verify: summary totals updated correctly
6. Verify: can approve/reject the manual_time activity
7. Delete the quart, verify it disappears completely

- [ ] **Step 2: Test clock extension**

1. Edit a clock-out to a later time
2. Verify: info banner shows "+X min" in the popover
3. Verify: reason is mandatory
4. Submit with reason
5. Verify: "Temps manuel ajouté" segment appears in the quart
6. Verify: amber background, MANUEL badge, reason displayed
7. Delete the manual time entry, verify clock-out reverts

- [ ] **Step 3: Test empty day manual quart**

1. Find an employee with no shifts on a given day
2. Click the empty day cell in the approval grid → should open panel
3. Verify: empty state shown with "Aucun quart enregistré" and "+ Ajouter du temps manuel"
4. Add a manual quart → verify it appears correctly
5. The day should now show as having activities in the grid

- [ ] **Step 4: Test edge cases**

- Try to add overlapping manual time → should show error
- Try to extend clock-out without reason → should be blocked
- Try to delete manual time on approved day → should show error
- Reopen approved day with manual time, verify it becomes editable

- [ ] **Step 5: Build check**

Run: `cd dashboard && npx next build`
Expected: Build passes with no type errors.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat: manual time segments - complete implementation"
```
