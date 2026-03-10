# Callback Shifts (Rappels) & Employee Categories Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add callback shift detection (17h-5h auto-flag), 3-hour minimum billing with grouping logic, supervisor override, and employee category periods (renovation/entretien/menage/admin).

**Architecture:** Two independent features sharing one migration. Callback detection via DB trigger on shifts table insert. Approval RPCs updated to include call info and 3h minimum calculation with grouping. Employee categories follow the existing `employee_vehicle_periods` pattern (period-based CRUD).

**Tech Stack:** PostgreSQL (Supabase migrations), Next.js 14+ dashboard (shadcn/ui, TypeScript), Flutter/Dart (Riverpod, SQLCipher)

**Spec:** `docs/superpowers/specs/2026-03-10-callback-shifts-and-employee-categories-design.md`

---

## Chunk 1: Database Schema & RPCs

### Task 1: Migration — Add shift_type columns and trigger

**Files:**
- Create: `supabase/migrations/20260310050000_callback_shifts.sql`

- [ ] **Step 1: Write the migration SQL**

```sql
-- Migration: Callback shifts (rappels au travail)
-- Adds shift_type detection for callback shifts per Article 58 LNT Quebec
-- Auto-detects shifts clocked in between 17:00-05:00 (America/Montreal)

-- 1. Add columns to shifts
ALTER TABLE shifts ADD COLUMN shift_type TEXT NOT NULL DEFAULT 'regular';
ALTER TABLE shifts ADD COLUMN shift_type_source TEXT NOT NULL DEFAULT 'auto';
ALTER TABLE shifts ADD COLUMN shift_type_changed_by UUID REFERENCES employee_profiles(id);

-- Add CHECK constraints
ALTER TABLE shifts ADD CONSTRAINT chk_shift_type CHECK (shift_type IN ('regular', 'call'));
ALTER TABLE shifts ADD CONSTRAINT chk_shift_type_source CHECK (shift_type_source IN ('auto', 'manual'));

-- Index for filtering call shifts
CREATE INDEX idx_shifts_type ON shifts(shift_type) WHERE shift_type = 'call';

-- 2. Trigger: auto-detect callback on insert
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
  local_hour INTEGER;
BEGIN
  -- Extract hour in Montreal timezone
  local_hour := EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal');
  -- Between 17:00 (17) and 04:59 (< 5) = callback
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

-- 3. RPC: update_shift_type (supervisor override)
CREATE OR REPLACE FUNCTION update_shift_type(
  p_shift_id UUID,
  p_shift_type TEXT,
  p_changed_by UUID
)
RETURNS JSONB AS $$
BEGIN
  IF p_shift_type NOT IN ('regular', 'call') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid shift_type: must be regular or call');
  END IF;

  UPDATE shifts
  SET shift_type = p_shift_type,
      shift_type_source = 'manual',
      shift_type_changed_by = p_changed_by
  WHERE id = p_shift_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Shift not found');
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Comments
COMMENT ON COLUMN shifts.shift_type IS 'ROLE: Type de quart | VALUES: regular (normal), call (rappel au travail Art.58 LNT) | DEFAULT: regular | TRIGGER: auto-set to call when clocked_in_at between 17h-5h Montreal';
COMMENT ON COLUMN shifts.shift_type_source IS 'ROLE: Source de la classification | VALUES: auto (trigger), manual (superviseur) | DEFAULT: auto';
COMMENT ON COLUMN shifts.shift_type_changed_by IS 'ROLE: Superviseur ayant modifié la classification | NULL si auto-détecté';
COMMENT ON FUNCTION set_shift_type_on_insert IS 'Auto-detects callback shifts: clocked_in_at between 17:00-04:59 America/Montreal = call';
COMMENT ON FUNCTION update_shift_type IS 'Supervisor override to change shift classification between regular and call';
```

- [ ] **Step 2: Apply migration**

Run: `supabase migration apply` (via MCP apply_migration)
Expected: Migration applied successfully

- [ ] **Step 3: Verify trigger works**

Run via execute_sql:
```sql
-- Verify columns exist
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'shifts' AND column_name LIKE 'shift_type%'
ORDER BY column_name;
```
Expected: 3 rows (shift_type, shift_type_source, shift_type_changed_by)

- [ ] **Step 4: Verify existing shifts default to 'regular'**

Run via execute_sql:
```sql
SELECT shift_type, COUNT(*) FROM shifts GROUP BY shift_type;
```
Expected: All existing shifts show 'regular'

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260310050000_callback_shifts.sql
git commit -m "feat: add shift_type columns and auto-detect trigger for callback shifts (rappels)"
```

---

### Task 2: Migration — Create employee_categories table

**Files:**
- Create: `supabase/migrations/20260310060000_employee_categories.sql`

- [ ] **Step 1: Write the migration SQL**

```sql
-- Migration: Employee categories (period-based)
-- Tracks employee job categories: renovation, entretien, menage, admin
-- An employee can have multiple active categories simultaneously

CREATE TABLE employee_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK (category IN ('renovation', 'entretien', 'menage', 'admin')),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing period
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_employee_categories_employee ON employee_categories(employee_id);
CREATE INDEX idx_employee_categories_active ON employee_categories(employee_id) WHERE ended_at IS NULL;
CREATE INDEX idx_employee_categories_dates ON employee_categories(started_at, ended_at);

-- Prevent exact duplicate periods (same employee + category + start date)
ALTER TABLE employee_categories
  ADD CONSTRAINT no_duplicate_category_period UNIQUE (employee_id, category, started_at);

-- Updated_at trigger (reuse existing function)
CREATE TRIGGER trg_employee_categories_updated_at
    BEFORE UPDATE ON employee_categories
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE employee_categories ENABLE ROW LEVEL SECURITY;

-- Admin/super_admin can do everything
CREATE POLICY "Admins manage employee categories"
    ON employee_categories FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- Employees can view their own categories
CREATE POLICY "Employees view own categories"
    ON employee_categories FOR SELECT
    USING (employee_id = auth.uid());

-- Comments
COMMENT ON TABLE employee_categories IS 'ROLE: Catégories de poste des employés par période | CATEGORIES: renovation, entretien, menage, admin | REGLES: Un employé peut avoir plusieurs catégories actives simultanément (ex: menage + admin). ended_at NULL = période en cours.';
COMMENT ON COLUMN employee_categories.category IS 'ROLE: Type de poste | VALUES: renovation (Rénovation), entretien (Entretien/Maintenance), menage (Ménage), admin (Administration)';
COMMENT ON COLUMN employee_categories.started_at IS 'ROLE: Date de début de la période | FORMAT: DATE';
COMMENT ON COLUMN employee_categories.ended_at IS 'ROLE: Date de fin de la période | NULL = toujours actif';
```

- [ ] **Step 2: Apply migration**

Run: `supabase migration apply` (via MCP apply_migration)
Expected: Migration applied successfully

- [ ] **Step 3: Verify table exists**

Run via execute_sql:
```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'employee_categories' ORDER BY ordinal_position;
```
Expected: 6 columns (id, employee_id, category, started_at, ended_at, created_at, updated_at)

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260310060000_employee_categories.sql
git commit -m "feat: add employee_categories table for period-based job categories"
```

---

### Task 3: Migration — Update approval RPCs with call info

**Files:**
- Create: `supabase/migrations/20260310070000_approval_rpcs_callback_support.sql`

This is the most complex task. The RPCs need to:
1. Include `shift_type` info in day detail activities
2. Calculate 3h minimum with grouping logic in weekly summary
3. Add call-related fields to the output

- [ ] **Step 1: Write the migration — update `_get_day_approval_detail_base`**

**CRITICAL: DO NOT rewrite this function from scratch.** Copy the ENTIRE current version from `20260310010000_restore_lunch_in_approvals.sql` and apply these minimal diffs:

**Diff 1 — Add variables after `v_has_active_shift BOOLEAN`:**
```sql
    v_call_count INTEGER := 0;
    v_call_billed_minutes INTEGER := 0;
```

**Diff 2 — Add call grouping calculation block AFTER the lunch subtraction (`v_total_shift_minutes := GREATEST(...)`):**
```sql
    -- Calculate call billing with grouping logic (Article 58 LNT)
    -- Grouping: if a call starts within the 3h billing window of a previous call, they merge.
    -- Checking only the previous shift's window is sufficient because each shift in a group
    -- has start+3h >= the original window, so the window can only grow forward.
    WITH call_shifts_ordered AS (
        SELECT
            id,
            clocked_in_at,
            clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY clocked_in_at) AS rn
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND shift_type = 'call'
          AND status = 'completed'
    ),
    call_with_groups AS (
        SELECT
            cs.*,
            SUM(CASE
                WHEN cs.rn = 1 THEN 1
                WHEN cs.clocked_in_at >= (
                    SELECT GREATEST(
                        prev.clocked_in_at + INTERVAL '3 hours',
                        COALESCE(prev.clocked_out_at, prev.clocked_in_at + INTERVAL '3 hours')
                    )
                    FROM call_shifts_ordered prev
                    WHERE prev.rn = cs.rn - 1
                ) THEN 1
                ELSE 0
            END) OVER (ORDER BY cs.rn) AS group_id
        FROM call_shifts_ordered cs
    ),
    call_group_billing AS (
        SELECT
            group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(
                EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
                180  -- 3h minimum per group
            )::INTEGER AS group_billed_minutes
        FROM call_with_groups
        GROUP BY group_id
    )
    SELECT
        COALESCE(SUM(shifts_in_group), 0)::INTEGER,
        COALESCE(SUM(group_billed_minutes), 0)::INTEGER
    INTO v_call_count, v_call_billed_minutes
    FROM call_group_billing;
```

**Diff 3 — Add `shift_type` and `shift_type_source` columns to the `clock_data` CTE:**

In the clock_in SELECT (after the last `NULL::TEXT AS end_location_type`), add:
```sql
            s.shift_type::TEXT AS shift_type,
            s.shift_type_source::TEXT AS shift_type_source
```

In the clock_out UNION ALL SELECT, add at the same position:
```sql
            s.shift_type::TEXT,
            s.shift_type_source::TEXT
```

In ALL other CTEs (stop_data, trip_data, lunch_data), add at the same position:
```sql
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
```

**Diff 4 — Add `shift_type` and `shift_type_source` to the `jsonb_build_object` in the activity aggregation:**
```sql
            'shift_type', shift_type,
            'shift_type_source', shift_type_source
```

**Diff 5 — Add call fields to the summary `jsonb_build_object`:**
```sql
            'call_count', v_call_count,
            'call_billed_minutes', v_call_billed_minutes
```

**Verify:** All existing logic (stops, trips, lunch, overrides) must be preserved exactly as-is.

- [ ] **Step 2: Write the migration — update `get_weekly_approval_summary`**

**Same approach: copy existing function, apply minimal diffs.**

Add a new CTE `day_calls` after `day_lunch`. This CTE first groups call shifts, then aggregates per-group billing to per-day totals:

```sql
-- Add this CTE to get_weekly_approval_summary, after day_lunch
day_calls AS (
    -- Step 1: Assign group IDs to call shifts
    -- Calls within 3h window of previous call are in the same group
    SELECT
        employee_id,
        clocked_in_at::DATE AS call_date,
        clocked_in_at,
        clocked_out_at,
        SUM(CASE
            WHEN LAG(clocked_in_at) OVER w IS NULL THEN 1
            WHEN clocked_in_at >= GREATEST(
                LAG(clocked_in_at) OVER w + INTERVAL '3 hours',
                LAG(clocked_out_at) OVER w
            ) THEN 1
            ELSE 0
        END) OVER w AS group_id
    FROM shifts
    WHERE shift_type = 'call'
      AND status = 'completed'
      AND clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
      AND employee_id IN (SELECT employee_id FROM employee_list)
    WINDOW w AS (PARTITION BY employee_id, clocked_in_at::DATE ORDER BY clocked_in_at)
),
-- Step 2: Aggregate per group (one row per group)
day_call_groups AS (
    SELECT
        employee_id,
        call_date,
        group_id,
        COUNT(*) AS shifts_in_group,
        GREATEST(
            EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
            180  -- 3h minimum per group
        )::INTEGER AS group_billed_minutes
    FROM day_calls
    GROUP BY employee_id, call_date, group_id
),
-- Step 3: Aggregate per employee per day
day_call_totals AS (
    SELECT
        employee_id,
        call_date,
        SUM(shifts_in_group)::INTEGER AS call_count,
        SUM(group_billed_minutes)::INTEGER AS call_billed_minutes
    FROM day_call_groups
    GROUP BY employee_id, call_date
),
```

Then add to `pending_day_stats` CTE:
```sql
LEFT JOIN day_call_totals dct
    ON dct.employee_id = ds.employee_id AND dct.call_date = ds.shift_date
```

And add to the day output `jsonb_build_object`:
```sql
'call_count', COALESCE(dct.call_count, 0),
'call_billed_minutes', COALESCE(dct.call_billed_minutes, 0)
```

- [ ] **Step 3: Apply migration**

Run: `supabase migration apply` (via MCP apply_migration)

- [ ] **Step 4: Test with execute_sql**

```sql
-- Test the weekly summary returns call fields
SELECT jsonb_pretty(get_weekly_approval_summary('2026-03-03'::DATE));
```
Expected: Each day entry includes `call_count` and `call_billed_minutes` fields (both 0 for days without calls)

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260310070000_approval_rpcs_callback_support.sql
git commit -m "feat: update approval RPCs with callback shift support and 3h minimum grouping"
```

---

## Chunk 2: Dashboard UI

### Task 4: Dashboard types — Add call fields

**Files:**
- Modify: `dashboard/src/types/mileage.ts`

- [ ] **Step 1: Add shift_type to ApprovalActivity type**

In `ApprovalActivity` interface (around line 266), add after `end_location_type`:
```typescript
  shift_type: 'regular' | 'call' | null;
  shift_type_source: 'auto' | 'manual' | null;
```

- [ ] **Step 2: Add call fields to DayApprovalDetail summary**

In the `summary` type within `DayApprovalDetail` (around line 297), add:
```typescript
    call_count: number;
    call_billed_minutes: number;
```

- [ ] **Step 3: Add call fields to WeeklyDayEntry**

In `WeeklyDayEntry` interface (around line 308), add:
```typescript
  call_count: number;
  call_billed_minutes: number;
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add callback shift types to approval interfaces"
```

---

### Task 5: Dashboard — Approval grid call indicator

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx`

- [ ] **Step 1: Add call indicator to day cells**

In the cell rendering section (where status badges are shown), add a conditional call badge:

After the existing status badge rendering, add:
```typescript
{day.call_count > 0 && (
  <div className="flex items-center gap-1 mt-0.5">
    <Phone className="h-3 w-3 text-orange-500" />
    <span className="text-[10px] text-orange-600 font-medium">
      {day.call_count} rappel{day.call_count > 1 ? 's' : ''}
    </span>
  </div>
)}
```

- [ ] **Step 2: Add Phone import**

Add `Phone` to the lucide-react imports.

- [ ] **Step 3: Add call_billed_minutes to the tooltip/summary display**

Where total hours are shown per cell, add billed minutes display when calls exist:
```typescript
{day.call_billed_minutes > 0 && (
  <span className="text-[10px] text-orange-600">
    ({formatHours(day.call_billed_minutes)} facturées)
  </span>
)}
```

- [ ] **Step 4: Verify build**

Run: `cd dashboard && npm run build`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx
git commit -m "feat: add callback shift indicators to approval grid"
```

---

### Task 6: Dashboard — Day approval detail call rendering

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`
- Modify: `dashboard/src/components/approvals/approval-rows.tsx`

- [ ] **Step 1: Add call summary banner in day-approval-detail.tsx**

After the summary section (where total_shift_minutes, approved, rejected are shown), add a call summary banner when calls exist:

```typescript
{detail.summary.call_count > 0 && (
  <div className="rounded-md bg-orange-50 border border-orange-200 p-3 mb-4">
    <div className="flex items-center gap-2">
      <Phone className="h-4 w-4 text-orange-600" />
      <span className="font-medium text-orange-800">
        {detail.summary.call_count} rappel{detail.summary.call_count > 1 ? 's' : ''} au travail
      </span>
    </div>
    <p className="text-sm text-orange-700 mt-1">
      Heures facturées (min. 3h/rappel) : {formatHours(detail.summary.call_billed_minutes)}
    </p>
  </div>
)}
```

- [ ] **Step 2: Add shift_type override buttons**

In the activity row rendering for clock_in events, when `shift_type` is present, add toggle buttons:

```typescript
{activity.activity_type === 'clock_in' && activity.shift_type !== null && (
  <div className="flex items-center gap-1 ml-2">
    {activity.shift_type === 'call' ? (
      <>
        <Badge className="bg-orange-100 text-orange-700 text-[10px]">
          <Phone className="h-3 w-3 mr-0.5" />
          Rappel {activity.shift_type_source === 'auto' ? '(auto)' : '(manuel)'}
        </Badge>
        <Button
          variant="ghost"
          size="sm"
          className="h-6 text-[10px] text-muted-foreground"
          onClick={() => handleShiftTypeToggle(activity.activity_id, 'regular')}
        >
          Retirer rappel
        </Button>
      </>
    ) : (
      <Button
        variant="ghost"
        size="sm"
        className="h-6 text-[10px] text-orange-600"
        onClick={() => handleShiftTypeToggle(activity.activity_id, 'call')}
      >
        <Phone className="h-3 w-3 mr-0.5" />
        Marquer comme rappel
      </Button>
    )}
  </div>
)}
```

- [ ] **Step 3: Add handleShiftTypeToggle function**

```typescript
const handleShiftTypeToggle = async (shiftId: string, newType: 'regular' | 'call') => {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return;

  const { data, error } = await supabaseClient.rpc('update_shift_type', {
    p_shift_id: shiftId,
    p_shift_type: newType,
    p_changed_by: user.id,
  });

  if (error) {
    toast.error(`Erreur: ${error.message}`);
    return;
  }

  toast.success(newType === 'call' ? 'Marqué comme rappel' : 'Rappel retiré');
  refetch(); // Re-fetch day detail
};
```

- [ ] **Step 4: Add visual distinction to call shift rows in approval-rows.tsx**

In `MergedLocationRow` and `ActivityRow` components, when the parent shift is a call, add an orange left border:

```typescript
// In the row's className, add conditional styling based on shift_type
className={cn(
  "...", // existing classes
  activity.shift_type === 'call' && "border-l-2 border-l-orange-400 bg-orange-50/30"
)}
```

- [ ] **Step 5: Verify build**

Run: `cd dashboard && npm run build`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: add callback shift rendering and toggle in approval detail"
```

---

### Task 7: Dashboard — Employee categories tab on employee detail

**Files:**
- Create: `dashboard/src/components/employees/employee-categories-card.tsx` (new directory)
- Modify: `dashboard/src/app/dashboard/employees/[id]/page.tsx`

- [ ] **Step 0: Create directory**

Run: `mkdir -p dashboard/src/components/employees`

- [ ] **Step 1: Create employee-categories-card.tsx**

Follow the pattern from `vehicle-periods-tab.tsx` but simplified for the employee detail page context. The component receives `employeeId` as prop (not a global tab).

Key differences from vehicle-periods-tab:
- No employee selector (fixed to current employee)
- Category select instead of vehicle type (renovation, entretien, menage, admin)
- No notes field
- French labels: "Rénovation", "Entretien", "Ménage", "Administration"

```typescript
'use client';

import { useState, useEffect, useCallback } from 'react';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Plus, Pencil, Trash2, Briefcase, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { toLocalDateString } from '@/lib/utils/date-utils';

// ... (full component following vehicle-periods-tab pattern)
// See spec for full implementation details
```

- [ ] **Step 2: Add EmployeeCategoriesCard to employee detail page**

In `dashboard/src/app/dashboard/employees/[id]/page.tsx`, after the Supervisor Assignment card:

```typescript
import { EmployeeCategoriesCard } from '@/components/employees/employee-categories-card';
```

Add after the `</div>` that closes the `grid gap-6 lg:grid-cols-2`:

```typescript
{/* Employee Categories */}
<EmployeeCategoriesCard employeeId={employeeId} isDisabled={!canEdit} />
```

- [ ] **Step 3: Verify build**

Run: `cd dashboard && npm run build`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/employees/employee-categories-card.tsx dashboard/src/app/dashboard/employees/\[id\]/page.tsx
git commit -m "feat: add employee categories management to employee detail page"
```

---

## Chunk 3: Flutter Mobile

### Task 8: Flutter — Add shiftType to Shift model

**Files:**
- Modify: `gps_tracker/lib/features/shifts/models/shift.dart`
- Modify: `gps_tracker/lib/features/shifts/models/shift_enums.dart`

- [ ] **Step 1: Add ShiftType enum to shift_enums.dart**

After the existing enums, add:
```dart
/// Type of shift: regular work or callback (rappel au travail)
enum ShiftType {
  regular,
  call;

  factory ShiftType.fromJson(String value) {
    switch (value) {
      case 'call':
        return ShiftType.call;
      case 'regular':
      default:
        return ShiftType.regular;
    }
  }

  String toJson() => name;

  String get displayLabel {
    switch (this) {
      case ShiftType.regular:
        return 'Régulier';
      case ShiftType.call:
        return 'Rappel';
    }
  }
}
```

- [ ] **Step 2: Add shiftType field to Shift model in shift.dart**

Add field:
```dart
final ShiftType shiftType;
```

Add to constructor with default:
```dart
this.shiftType = ShiftType.regular,
```

Add to fromJson:
```dart
shiftType: json['shift_type'] != null
    ? ShiftType.fromJson(json['shift_type'] as String)
    : ShiftType.regular,
```

Add to toJson:
```dart
'shift_type': shiftType.toJson(),
```

Add to copyWith:
```dart
ShiftType? shiftType,
```
And in the body:
```dart
shiftType: shiftType ?? this.shiftType,
```

- [ ] **Step 3: Add isCallback computed property**

```dart
/// Whether this is a callback shift (rappel au travail)
bool get isCallback => shiftType == ShiftType.call;
```

- [ ] **Step 4: Note on Shift equality**

The current `Shift.operator ==` only compares by `id`, which is correct — two shifts with the same ID but different shiftType are the same shift (type was just updated). No change needed to equality/hashCode.

- [ ] **Step 5: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/features/shifts/models/shift.dart gps_tracker/lib/features/shifts/models/shift_enums.dart
git commit -m "feat: add ShiftType enum and shiftType field to Shift model"
```

---

### Task 9: Flutter — Add shiftType to LocalShift and SQLCipher

**Files:**
- Modify: `gps_tracker/lib/features/shifts/models/local_shift.dart`
- Modify: `gps_tracker/lib/shared/services/local_database.dart`

- [ ] **Step 1: Add shiftType to LocalShift model**

Add field:
```dart
final String shiftType; // 'regular' or 'call'
```

Add to constructor:
```dart
this.shiftType = 'regular',
```

Add to fromMap (SQLite):
```dart
shiftType: map['shift_type'] as String? ?? 'regular',
```

Add to toMap:
```dart
'shift_type': shiftType,
```

Update toShift() to include:
```dart
shiftType: ShiftType.fromJson(shiftType),
```

Update fromShift() to include:
```dart
shiftType: shift.shiftType.toJson(),
```

- [ ] **Step 2: Add migration in local_database.dart**

In the `_onCreate` method, add `shift_type TEXT NOT NULL DEFAULT 'regular'` to the `local_shifts` CREATE TABLE.

In `_onUpgrade`, add a new version migration:
```dart
if (oldVersion < 9) {
  await db.execute("ALTER TABLE local_shifts ADD COLUMN shift_type TEXT NOT NULL DEFAULT 'regular'");
}
```

Update `_databaseVersion` from `8` to `9`.

- [ ] **Step 3: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/models/local_shift.dart gps_tracker/lib/shared/services/local_database.dart
git commit -m "feat: add shiftType to LocalShift model and SQLCipher schema"
```

---

### Task 10: Flutter — Show "Rappel" tag in shift history

**Files:**
- Modify: `gps_tracker/lib/features/history/widgets/shift_history_card.dart`

- [ ] **Step 1: Add Rappel badge to ShiftHistoryCard**

In the `build` method, in the first `Row` children (after the status indicator dot and before the Spacer), add a callback badge:

```dart
if (shift.isCallback) ...[
  const SizedBox(width: 6),
  Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.orange.shade200),
    ),
    child: Text(
      'Rappel',
      style: theme.textTheme.labelSmall?.copyWith(
        color: Colors.orange.shade700,
        fontWeight: FontWeight.w600,
        fontSize: 10,
      ),
    ),
  ),
],
```

- [ ] **Step 2: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/history/widgets/shift_history_card.dart
git commit -m "feat: show Rappel badge on callback shifts in history"
```

---

### Task 11: Flutter — Show "Rappel — minimum 3h" in shift detail screen

**Files:**
- Modify: `gps_tracker/lib/features/history/screens/shift_detail_screen.dart`

- [ ] **Step 1: Add Rappel info card to shift detail**

In the shift detail screen, after the existing Status card and before the Time card, add a callback info card when the shift is a call:

```dart
if (shift.isCallback) ...[
  Card(
    color: Colors.orange.shade50,
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.phone_callback, color: Colors.orange.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Rappel au travail',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (shift.duration.inMinutes < 180)
                  Text(
                    'Minimum 3h facturées (Art. 58 LNT)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade700,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
],
```

- [ ] **Step 2: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/history/screens/shift_detail_screen.dart
git commit -m "feat: show Rappel info card in shift detail screen"
```

---

### Task 12: Final verification and CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run full dashboard build**

Run: `cd dashboard && npm run build`
Expected: Build succeeds

- [ ] **Step 2: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors (or only pre-existing warnings)

- [ ] **Step 3: Verify approval RPCs return call fields**

Run via execute_sql:
```sql
SELECT jsonb_pretty(get_weekly_approval_summary('2026-03-03'::DATE));
```
Verify: Each day entry has `call_count` and `call_billed_minutes`

- [ ] **Step 4: Update CLAUDE.md Recent Changes**

Add entry documenting the callback shifts and employee categories feature.

- [ ] **Step 5: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with callback shifts and employee categories"
```
