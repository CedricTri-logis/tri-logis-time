-- ============================================================
-- Migration: Fix needs_review_count to exclude clock events merged into gaps
--
-- Bug: The needs_review_count calculation in _get_day_approval_detail_base
-- excluded clock events that overlap with stops (±60s) but NOT gaps.
-- The frontend's mergeClockEvents merges clocks into stops, stop_segments,
-- AND gaps. When a clock_out occurs after a GPS gap (no nearby stop),
-- the frontend merges it into the gap (hiding it from the UI), but the
-- server still counted it as needs_review → blocking day approval.
--
-- Fix: Add 'gap' to the activity_type check so clock events overlapping
-- gaps are also excluded from needs_review_count.
-- ============================================================

DO $outer$
DECLARE
    v_src TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    v_old := E's->>''activity_type'' IN (''stop'', ''stop_segment'')';
    v_new := E's->>''activity_type'' IN (''stop'', ''stop_segment'', ''gap'')';

    SELECT prosrc INTO v_src FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    IF v_src NOT LIKE '%' || v_old || '%' THEN
        -- Already patched or function changed — skip silently
        RAISE NOTICE 'Target string not found in _get_day_approval_detail_base, skipping (may already be patched)';
        RETURN;
    END IF;

    v_src := replace(v_src, v_old, v_new);

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER',
        quote_literal(v_src)
    );
END;
$outer$;
