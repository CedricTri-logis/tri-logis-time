-- ============================================================
-- Migration: Fix phantom needs_review from micro-shift clock events
--
-- Bug: When a micro-shift (<30s) has a clock_out without GPS,
-- it gets auto_status='needs_review'. The frontend hides micro-shift
-- clock events (mergeClockEvents filters shifts <30s), so
-- visibleNeedsReviewCount=0. But the SQL needs_review_count still
-- counts it because the 60s overlap heuristic doesn't find a nearby
-- stop for the orphaned clock event. This causes approve_day() to
-- reject with "1 activities still need review" even though the user
-- sees 0 activities to review.
--
-- Fix: Always exclude clock_in/clock_out/lunch from needs_review_count.
-- These are 0-duration metadata events that should never block approval.
-- The old 60s overlap heuristic was fragile and didn't handle all cases.
-- ============================================================

DO $outer$
DECLARE
    v_src TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    -- The old code conditionally excluded clock events only if they overlapped
    -- with a stop/gap within 60 seconds. We replace it with unconditional exclusion.
    v_old := 'AND NOT (
                a->>''activity_type'' IN (''clock_in'', ''clock_out'', ''lunch'')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, ''[]''::JSONB)) s
                    WHERE s->>''activity_type'' IN (''stop'', ''stop_segment'', ''gap'', ''gap_segment'')
                      AND (a->>''started_at'')::TIMESTAMPTZ >= ((s->>''started_at'')::TIMESTAMPTZ - INTERVAL ''60 seconds'')
                      AND (a->>''started_at'')::TIMESTAMPTZ <= ((s->>''ended_at'')::TIMESTAMPTZ + INTERVAL ''60 seconds'')
                )
            )';

    v_new := 'AND a->>''activity_type'' NOT IN (''clock_in'', ''clock_out'', ''lunch'')';

    SELECT prosrc INTO v_src FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    IF v_src IS NULL THEN
        RAISE NOTICE 'Function _get_day_approval_detail_base not found, skipping';
        RETURN;
    END IF;

    IF v_src NOT LIKE '%' || 'AND NOT (' || '%clock_in%' || 'AND EXISTS%60 seconds%' THEN
        RAISE NOTICE 'Target pattern not found in _get_day_approval_detail_base, skipping (may already be patched)';
        RETURN;
    END IF;

    v_src := replace(v_src, v_old, v_new);

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Successfully patched _get_day_approval_detail_base: clock events always excluded from needs_review_count';
END;
$outer$;
