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
