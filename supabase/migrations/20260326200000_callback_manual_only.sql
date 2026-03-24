-- Migration: Callback shifts must be manual only
--
-- Problem: The auto-detect trigger sets shift_type='call' for any shift clocked in 17h-5h.
-- This causes false callback bonus (+2h25) on regular evening shifts. Supervisors must
-- explicitly mark a shift as "rappel" during the approval workflow.
--
-- Also: a fully-rejected shift should never produce callback bonus (chiffre rejeté = 0h).
--
-- Changes:
--   1. Drop auto-detect trigger (callbacks = manual only)
--   2. Reset all auto-detected 'call' shifts back to 'regular'
--   3. Patch _get_day_approval_detail_base: zero out callback bonus when approved=0
--   4. Patch get_weekly_approval_summary: same logic

-- ============================================================
-- PART 1: Remove auto-detect trigger
-- ============================================================
DROP TRIGGER IF EXISTS trg_set_shift_type ON shifts;
DROP TRIGGER IF EXISTS trg_set_shift_type_on_insert ON shifts;
DROP FUNCTION IF EXISTS set_shift_type_on_insert() CASCADE;

-- ============================================================
-- PART 2: Reset all auto-detected callback shifts to regular
-- ============================================================
UPDATE shifts
SET shift_type = 'regular'
WHERE shift_type = 'call'
  AND shift_type_source = 'auto';

-- ============================================================
-- PART 3: Patch _get_day_approval_detail_base
--         Zero out callback bonus when all activities rejected
-- ============================================================
DO $$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Insert callback guard after the rejected cap (added by fix_approval_overcount)
    v_old := 'v_rejected_minutes := LEAST(v_rejected_minutes, GREATEST(v_total_shift_minutes - v_approved_minutes, 0));';

    v_new := 'v_rejected_minutes := LEAST(v_rejected_minutes, GREATEST(v_total_shift_minutes - v_approved_minutes, 0));

    -- No callback bonus when all activities are rejected (chiffre rejeté = 0h)
    IF v_approved_minutes = 0 THEN
        v_call_bonus_minutes := 0;
        v_call_billed_minutes := 0;
        v_call_count := 0;
    END IF;';

    IF v_funcdef LIKE '%' || v_old || '%' THEN
        v_funcdef := replace(v_funcdef, v_old, v_new);
        EXECUTE v_funcdef;
    ELSE
        RAISE EXCEPTION 'PART 3: Could not find rejected cap pattern in _get_day_approval_detail_base';
    END IF;
END;
$$;

-- ============================================================
-- PART 4: Patch get_weekly_approval_summary
--         Zero out callback bonus when approved_minutes = 0
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

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Replace the call_bonus_minutes in pending_day_stats CTE
    -- Zero out when approved_minutes for the day is 0
    v_old := $str$COALESCE(dct.call_bonus_minutes, 0) AS call_bonus_minutes,$str$;

    v_new := $str$CASE WHEN COALESCE(
                CASE WHEN ea.status = 'approved' THEN ea.approved_minutes
                     ELSE ldt.live_approved END,
                0) > 0
            THEN COALESCE(dct.call_bonus_minutes, 0) ELSE 0 END AS call_bonus_minutes,$str$;

    IF v_funcdef LIKE '%' || v_old || '%' THEN
        v_funcdef := replace(v_funcdef, v_old, v_new);
        EXECUTE v_funcdef;
    ELSE
        RAISE NOTICE 'PART 4: Pattern not found — weekly summary may have been updated already';
    END IF;
END;
$migration$;
