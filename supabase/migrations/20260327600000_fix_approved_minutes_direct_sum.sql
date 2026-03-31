-- ============================================================
-- Migration: Fix approved_minutes calculation in approve_day()
--
-- Bug: Migration 20260326600000 Part 3 injected an override:
--      v_approved_minutes := v_total_shift_minutes - v_rejected_minutes
--   This subtraction is wrong because total_shift_minutes uses
--   effective_shift_times (clipped at last GPS point) while
--   rejected_minutes includes activities outside that window.
--   Result: approved_minutes = 86 min instead of 486 min.
--
-- Fix:
--   Part 1: Remove the override from approve_day() so it uses
--           the direct SUM from _get_day_approval_detail_base()
--   Part 2: Restore rejected cap + callback guard lost in 20260327200003
--   Part 3: Recalculate all frozen day_approvals with correct values
-- ============================================================

-- ============================================================
-- PART 1: Remove the override from approve_day()
-- ============================================================
DO $outer$
DECLARE
    v_src TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = 'approve_day'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION 'approve_day not found';
    END IF;

    -- Remove the injected override (2 comment lines + assignment + blank line)
    v_src := replace(
        v_src,
        '-- Approving a day means all non-rejected time is approved.
    -- Override the activity-level sum to fill any micro-gaps.
    v_approved_minutes := v_total_shift_minutes - v_rejected_minutes;

    -- Upsert day_approvals with frozen values',
        '-- Upsert day_approvals with frozen values'
    );

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION approve_day(p_employee_id UUID, p_date DATE, p_notes TEXT DEFAULT NULL) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Part 1: Removed approved_minutes override from approve_day()';
END;
$outer$;

-- ============================================================
-- PART 2: Restore rejected cap + callback guard in _get_day_approval_detail_base
--         Lost when 20260327200003 fully rewrote the function without them.
--         Originally added by 20260324300000 (rejected cap) and
--         20260326200000 (callback guard).
-- ============================================================
DO $outer$
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

    v_old := '-- Cap approved minutes at shift duration (activities can extend beyond shift boundaries)
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);

    v_result := jsonb_build_object(';

    v_new := '-- Cap approved and rejected minutes so their sum cannot exceed total shift duration.
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);
    v_rejected_minutes := LEAST(v_rejected_minutes, GREATEST(v_total_shift_minutes - v_approved_minutes, 0));

    -- No callback bonus when all activities are rejected
    IF v_approved_minutes = 0 THEN
        v_call_bonus_minutes := 0;
        v_call_billed_minutes := 0;
        v_call_count := 0;
    END IF;

    v_result := jsonb_build_object(';

    IF v_funcdef LIKE '%' || v_old || '%' THEN
        v_funcdef := replace(v_funcdef, v_old, v_new);
        EXECUTE v_funcdef;
        RAISE NOTICE 'Part 2: Restored rejected cap + callback guard';
    ELSE
        RAISE EXCEPTION 'Part 2: Could not find cap pattern in _get_day_approval_detail_base';
    END IF;
END;
$outer$;

-- ============================================================
-- PART 3: Recalculate frozen values for all approved days
--
-- _get_day_approval_detail_base returns frozen values when
-- status = 'approved', so we temporarily flip to 'pending'
-- to force live computation, then restore 'approved'.
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
    ALTER TABLE day_approvals DISABLE TRIGGER trg_payroll_lock_day_approvals;

    -- Step 1: Temporarily set all approved days to 'pending'
    UPDATE day_approvals SET status = 'pending' WHERE status = 'approved';

    -- Step 2: Recalculate using live values
    FOR r IN
        SELECT da.id, da.employee_id, da.date,
               da.approved_minutes AS old_approved,
               da.rejected_minutes AS old_rejected,
               da.total_shift_minutes AS old_total
        FROM day_approvals da
        WHERE da.approved_by IS NOT NULL  -- was previously approved
    LOOP
        v_detail := _get_day_approval_detail_base(r.employee_id, r.date);

        v_new_total := (v_detail->'summary'->>'total_shift_minutes')::INTEGER;
        v_new_approved := (v_detail->'summary'->>'approved_minutes')::INTEGER;
        v_new_rejected := (v_detail->'summary'->>'rejected_minutes')::INTEGER;

        UPDATE day_approvals
        SET status = 'approved',
            total_shift_minutes = v_new_total,
            approved_minutes = v_new_approved,
            rejected_minutes = v_new_rejected
        WHERE id = r.id;

        IF v_new_approved IS DISTINCT FROM r.old_approved
           OR v_new_rejected IS DISTINCT FROM r.old_rejected THEN
            v_fixed_count := v_fixed_count + 1;
            RAISE NOTICE 'Fixed %: approved % -> %, rejected % -> %',
                r.date, r.old_approved, v_new_approved, r.old_rejected, v_new_rejected;
        END IF;
    END LOOP;

    -- Step 3: Safety net — restore any missed rows
    UPDATE day_approvals SET status = 'approved'
    WHERE approved_by IS NOT NULL AND status = 'pending';

    ALTER TABLE day_approvals ENABLE TRIGGER trg_payroll_lock_day_approvals;

    RAISE NOTICE 'Part 2: Recalculated frozen values. % day(s) had changed values.', v_fixed_count;
END;
$$;
