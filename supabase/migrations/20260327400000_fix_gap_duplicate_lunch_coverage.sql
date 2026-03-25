-- ============================================================
-- Migration: Fix duplicate gap entries from non-overlapping lunch coverage
--
-- Bug: The lunch coverage events in gap detection join ALL lunches
-- sharing the same work_body_id to ALL work shifts, regardless of
-- time overlap. When a lunch starts AFTER a shift ends, the
-- GREATEST/LEAST clamping produces inverted events (start > end)
-- that create phantom coverage islands, generating duplicate gap
-- entries both starting at the same time.
--
-- Example: Shift 1 (06:55-07:42) gets lunches at 11:37 and 13:01
-- matched via work_body_id. Clamped events (11:37, 07:42) and
-- (13:01, 07:42) are inverted, creating phantom islands that
-- produce two gaps both starting at 07:42.
--
-- Fix: Add time overlap filter to the lunch join, matching the
-- pattern already used by the manual_time_entries join.
-- ============================================================

DO $outer$
DECLARE
    v_src TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    v_old := 'JOIN shifts s_lunch ON s_lunch.employee_id = p_employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL';

    v_new := 'JOIN shifts s_lunch ON s_lunch.employee_id = p_employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL
           AND s_lunch.clocked_in_at < sb.clocked_out_at
           AND s_lunch.clocked_out_at > sb.clocked_in_at';

    SELECT prosrc INTO v_src FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    IF v_src IS NULL THEN
        RAISE NOTICE 'Function _get_day_approval_detail_base not found, skipping';
        RETURN;
    END IF;

    IF v_src NOT LIKE '%' || v_old || '%' THEN
        RAISE NOTICE 'Target pattern not found in _get_day_approval_detail_base, skipping (may already be patched)';
        RETURN;
    END IF;

    v_src := replace(v_src, v_old, v_new);

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Successfully patched _get_day_approval_detail_base: lunch coverage events now require time overlap with shift';
END;
$outer$;
