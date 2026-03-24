# Fix Approval Hours Over-Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the bug where `approved_minutes + rejected_minutes > total_shift_minutes` in approval data, and recalculate corrupted historical records.

**Architecture:** Two-part fix: (1) patch the `_get_day_approval_detail_base` and `get_weekly_approval_summary` RPCs to cap `rejected_minutes` so `approved + rejected ≤ total`, and (2) recalculate the 10 corrupted frozen records in `day_approvals`. Both fixes are pure SQL migrations — no dashboard or Flutter changes needed.

**Tech Stack:** PostgreSQL (Supabase migrations), SQL

---

## Root Cause Summary

Three causes combine to produce `approved + rejected > total`:

1. **Activities outside shift boundaries** — GPS detects stops/trips before `clocked_in_at` or after `clocked_out_at`. These count in approved/rejected but NOT in `total_shift_minutes`.
2. **Asymmetric cap** — `approved_minutes` is capped via `LEAST(v_approved, v_total)` but `rejected_minutes` has NO cap.
3. **Stop/lunch overlap** — A stop starting before a lunch break ends gets its full duration approved, while the lunch is also fully subtracted from total.

## File Structure

```
supabase/migrations/
  20260324300000_fix_approval_overcount.sql   # NEW — RPC fix + data backfill
```

Single migration file containing:
- Part 1: Patch `_get_day_approval_detail_base` to cap rejected
- Part 2: Patch `get_weekly_approval_summary` to cap rejected (both frozen and live branches)
- Part 3: Recalculate frozen values for the 10 over-count records + sanity assertion

---

### Task 1: Verify current over-count state (pre-fix baseline)

**Files:** None (read-only verification)

- [ ] **Step 1: Run the over-count audit query to establish baseline**

```sql
-- Run via Supabase MCP execute_sql
SELECT
  ep.full_name,
  da.date,
  da.total_shift_minutes as total,
  da.approved_minutes as approved,
  da.rejected_minutes as rejected,
  (da.approved_minutes + da.rejected_minutes) - da.total_shift_minutes as over_by
FROM day_approvals da
JOIN employee_profiles ep ON ep.id = da.employee_id
WHERE da.status = 'approved'
  AND da.approved_minutes + da.rejected_minutes > da.total_shift_minutes
ORDER BY da.date DESC;
```

Expected: 10 rows with `over_by > 0`.

- [ ] **Step 2: Record the count for post-fix verification**

Note the exact count and save it mentally. We'll re-run this after the fix to confirm 0 rows.

---

### Task 2: Create the migration to fix the RPC and backfill data

**Files:**
- Create: `supabase/migrations/20260324300000_fix_approval_overcount.sql`

- [ ] **Step 1: Write the migration file**

The migration has 3 parts. Critical implementation notes:
- **Must** replace `'CREATE FUNCTION'` with `'CREATE OR REPLACE FUNCTION'` after `pg_get_functiondef()` (it outputs `CREATE FUNCTION` without `OR REPLACE`)
- **Must** use `$str$` dollar-quotes inside `DO $$` blocks to avoid collision
- **Must** match exact indentation from the live function (28 spaces before WHEN, 24 before END)
- `total_shift_minutes` in the weekly summary already excludes lunch — do NOT subtract lunch again

```sql
-- Migration: Fix approval over-count bug
-- Problem: approved_minutes + rejected_minutes can exceed total_shift_minutes
-- Root cause: rejected_minutes is not capped, and activities outside shift boundaries
--             are counted in approved/rejected but not in total_shift_minutes.
-- Fix: Cap rejected_minutes so that approved + rejected <= total.

-- ============================================================
-- PART 1: Patch _get_day_approval_detail_base
--         Add rejected cap after the existing approved cap
-- ============================================================
DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    -- pg_get_functiondef outputs CREATE FUNCTION, not CREATE OR REPLACE
    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Replace the single approved cap with both caps
    v_funcdef := replace(
        v_funcdef,
        '-- Cap approved minutes at shift duration (activities can extend beyond shift boundaries)
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);',
        '-- Cap approved and rejected minutes so their sum cannot exceed total shift duration.
    -- Activities can extend beyond shift boundaries (GPS detects stops/trips before clock-in
    -- or after clock-out), so raw sums can exceed total_shift_minutes.
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);
    v_rejected_minutes := LEAST(v_rejected_minutes, GREATEST(v_total_shift_minutes - v_approved_minutes, 0));'
    );

    EXECUTE v_funcdef;
END;
$$;

-- ============================================================
-- PART 2: Patch get_weekly_approval_summary
--         Cap rejected_minutes for BOTH frozen and live branches
--         Note: total_shift_minutes already excludes lunch in the CTE
-- ============================================================
DO $migration$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    -- pg_get_functiondef outputs CREATE FUNCTION, not CREATE OR REPLACE
    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Match exact indentation from the live function (28 spaces before WHEN, 24 before END)
    v_old := $str$'rejected_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                            ELSE COALESCE(pds.live_rejected, 0)
                        END$str$;

    -- Cap both branches: rejected <= GREATEST(total - approved, 0)
    -- For the frozen branch: defense-in-depth against future corruption
    -- For the live branch: prevents over-count from activities outside shift boundaries
    -- Note: total_shift_minutes already has lunch subtracted in the day_shifts CTE
    v_new := $str$'rejected_minutes', LEAST(
                            CASE
                                WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                                ELSE COALESCE(pds.live_rejected, 0)
                            END,
                            GREATEST(
                                COALESCE(pds.total_shift_minutes, 0)
                                - CASE
                                    WHEN pds.approval_status = 'approved' THEN COALESCE(pds.frozen_approved, 0)
                                    ELSE COALESCE(pds.live_approved, 0)
                                  END,
                                0
                            )
                        )$str$;

    -- Only apply if the old pattern exists (idempotent)
    IF v_funcdef LIKE '%' || v_old || '%' THEN
        v_funcdef := replace(v_funcdef, v_old, v_new);
        EXECUTE v_funcdef;
    ELSE
        RAISE NOTICE 'PART 2: Pattern not found — weekly summary may have been updated already';
    END IF;
END;
$migration$;

-- ============================================================
-- PART 3: Recalculate frozen values for over-count records
--         Uses the now-fixed _get_day_approval_detail_base RPC
-- ============================================================
DO $$
DECLARE
    r RECORD;
    v_detail JSONB;
    v_new_approved INTEGER;
    v_new_rejected INTEGER;
    v_new_total INTEGER;
    v_fixed_count INTEGER := 0;
BEGIN
    -- Find all approved days where approved + rejected > total
    FOR r IN
        SELECT da.id, da.employee_id, da.date, da.approved_by
        FROM day_approvals da
        WHERE da.status = 'approved'
          AND da.approved_minutes + da.rejected_minutes > da.total_shift_minutes
    LOOP
        -- Get fresh computation from the now-fixed RPC
        v_detail := _get_day_approval_detail_base(r.employee_id, r.date);

        v_new_total := (v_detail->'summary'->>'total_shift_minutes')::INTEGER;
        v_new_approved := (v_detail->'summary'->>'approved_minutes')::INTEGER;
        v_new_rejected := (v_detail->'summary'->>'rejected_minutes')::INTEGER;

        -- Update frozen values in-place (preserve approval status and metadata)
        UPDATE day_approvals
        SET total_shift_minutes = v_new_total,
            approved_minutes = v_new_approved,
            rejected_minutes = v_new_rejected
        WHERE id = r.id;

        v_fixed_count := v_fixed_count + 1;
        RAISE NOTICE 'Fixed day_approval % for % on %: total=%, approved=%, rejected=%',
            r.id, r.employee_id, r.date, v_new_total, v_new_approved, v_new_rejected;
    END LOOP;

    RAISE NOTICE 'PART 3: Fixed % over-count records', v_fixed_count;

    -- Sanity check: ensure no over-count records remain
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE status = 'approved'
          AND approved_minutes + rejected_minutes > total_shift_minutes
    ) THEN
        RAISE EXCEPTION 'Backfill failed: over-count records still exist after fix';
    END IF;
END;
$$;
```

- [ ] **Step 2: Verify the migration file is syntactically complete**

Read the file back to confirm it's well-formed.

---

### Task 3: Apply the migration and verify

**Files:**
- Apply: `supabase/migrations/20260324300000_fix_approval_overcount.sql`

- [ ] **Step 1: Apply the migration via Supabase MCP**

Use `mcp__supabase__apply_migration` to apply the migration.

- [ ] **Step 2: Verify the RPC fix works — check Ozaka Lussier March 23**

```sql
SELECT
  (get_day_approval_detail(
    '11150c11-655f-42f8-90ef-fa71e5030eb1'::uuid,
    '2026-03-23'::date
  ))->'summary' as summary;
```

Expected: `approved_minutes + rejected_minutes <= total_shift_minutes`. The rejected should now be capped so the sum doesn't exceed total.

- [ ] **Step 3: Verify the backfill — re-run the over-count audit query**

```sql
SELECT
  ep.full_name,
  da.date,
  da.total_shift_minutes as total,
  da.approved_minutes as approved,
  da.rejected_minutes as rejected,
  (da.approved_minutes + da.rejected_minutes) - da.total_shift_minutes as over_by
FROM day_approvals da
JOIN employee_profiles ep ON ep.id = da.employee_id
WHERE da.status = 'approved'
  AND da.approved_minutes + da.rejected_minutes > da.total_shift_minutes
ORDER BY da.date DESC;
```

Expected: **0 rows**. All over-count records should be fixed.

- [ ] **Step 4: Verify the weekly summary is also fixed**

```sql
WITH weekly AS (
  SELECT jsonb_array_elements(
    get_weekly_approval_summary('2026-03-22'::date)
  ) as emp
),
days AS (
  SELECT
    emp->>'employee_name' as name,
    jsonb_array_elements(emp->'days') as d
  FROM weekly
)
SELECT name, d->>'date' as dt,
  (d->>'total_shift_minutes')::int as total,
  (d->>'approved_minutes')::int as approved,
  (d->>'rejected_minutes')::int as rejected
FROM days
WHERE (d->>'approved_minutes')::int + (d->>'rejected_minutes')::int
      > (d->>'total_shift_minutes')::int
  AND d->>'status' != 'no_shift';
```

Expected: **0 rows**.

- [ ] **Step 5: Verify no regressions — spot-check a correctly approved day**

```sql
-- Celine Santerre March 23 — was correct (approved=475, rejected=0, total=477)
SELECT
  da.total_shift_minutes, da.approved_minutes, da.rejected_minutes
FROM day_approvals da
JOIN employee_profiles ep ON ep.id = da.employee_id
WHERE ep.full_name = 'Celine Santerre' AND da.date = '2026-03-23';
```

Expected: Values should be unchanged (475/0/477).

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260324300000_fix_approval_overcount.sql
git commit -m "fix: cap rejected_minutes to prevent approval over-count

approved + rejected could exceed total_shift_minutes because:
1. GPS activities outside shift boundaries counted in approved/rejected
2. Only approved_minutes was capped, not rejected_minutes

Adds rejected cap: LEAST(rejected, GREATEST(total - approved, 0))
Caps both frozen and live branches in weekly summary.
Backfills 10 corrupted frozen records in day_approvals."
```
