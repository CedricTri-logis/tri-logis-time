-- =============================================================================
-- Migration: Recalculate ALL frozen approval totals
-- =============================================================================
-- Problem: approved_minutes and rejected_minutes frozen in day_approvals were
--          computed by older (buggy) versions of _get_day_approval_detail_base.
--          The fix_approval_overcount migration only recalculated records where
--          approved + rejected > total, missing cases where values were simply
--          wrong (e.g. rejected=0 despite rejected activities existing).
--
-- Fix: For every approved day, temporarily set status to 'pending' so the
--      current (fixed) _get_day_approval_detail_base computes fresh values
--      from live activity data, then re-freeze with correct totals.
-- =============================================================================

DO $$
DECLARE
    r RECORD;
    v_detail JSONB;
    v_new_approved INTEGER;
    v_new_rejected INTEGER;
    v_new_total INTEGER;
    v_old_approved INTEGER;
    v_old_rejected INTEGER;
    v_old_total INTEGER;
    v_changed_count INTEGER := 0;
    v_total_count INTEGER := 0;
BEGIN
    FOR r IN
        SELECT id, employee_id, date,
               approved_minutes, rejected_minutes, total_shift_minutes
        FROM day_approvals
        WHERE status = 'approved'
        ORDER BY date
    LOOP
        v_total_count := v_total_count + 1;
        v_old_approved := r.approved_minutes;
        v_old_rejected := r.rejected_minutes;
        v_old_total := r.total_shift_minutes;

        -- Temporarily set to pending so function computes live values
        UPDATE day_approvals SET status = 'pending' WHERE id = r.id;

        -- Get fresh computation from the current (fixed) function
        v_detail := _get_day_approval_detail_base(r.employee_id, r.date);

        v_new_total := (v_detail->'summary'->>'total_shift_minutes')::INTEGER;
        v_new_approved := (v_detail->'summary'->>'approved_minutes')::INTEGER;
        v_new_rejected := (v_detail->'summary'->>'rejected_minutes')::INTEGER;

        -- Restore approved status with fresh frozen values
        UPDATE day_approvals
        SET status = 'approved',
            total_shift_minutes = v_new_total,
            approved_minutes = v_new_approved,
            rejected_minutes = v_new_rejected
        WHERE id = r.id;

        IF v_new_approved IS DISTINCT FROM v_old_approved
           OR v_new_rejected IS DISTINCT FROM v_old_rejected
           OR v_new_total IS DISTINCT FROM v_old_total
        THEN
            v_changed_count := v_changed_count + 1;
            RAISE NOTICE 'CHANGED day_approval % for % on %: approved %->%, rejected %->%, total %->%',
                r.id, r.employee_id, r.date,
                v_old_approved, v_new_approved,
                v_old_rejected, v_new_rejected,
                v_old_total, v_new_total;
        END IF;
    END LOOP;

    RAISE NOTICE 'Recalculated % approved days, % had changed values', v_total_count, v_changed_count;
END;
$$;
