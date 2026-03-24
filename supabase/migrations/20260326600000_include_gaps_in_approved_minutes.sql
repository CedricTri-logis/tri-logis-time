-- ============================================================
-- Migration: Include gap/gap_segment in approved & rejected minutes
--
-- Bug: gap and gap_segment activities are excluded from approved_minutes
--      and rejected_minutes in _get_day_approval_detail_base, even when
--      their final_status is 'approved' or 'rejected'. But total_shift_minutes
--      includes the time covered by those gaps (clock-in to clock-out).
--      This creates a discrepancy: Total ≠ Approved + Rejected + NeedsReview.
--
-- Additionally, old approved days have gap activities that were never
-- explicitly overridden (still 'needs_review'), so even counting gaps
-- in approved wouldn't fix them. For approved days, all non-rejected
-- time is approved by definition.
--
-- Fix:
--   Part 1: Patch _get_day_approval_detail_base to include gap/gap_segment
--   Part 2: Fix frozen data: approved = total - rejected for all approved days
--   Part 3: Patch approve_day to freeze approved = total - rejected
-- ============================================================

-- ============================================================
-- PART 1: Patch _get_day_approval_detail_base
--         Remove gap/gap_segment from NOT IN exclusions
-- ============================================================
DO $outer$
DECLARE
    v_src TEXT;
    v_original TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION '_get_day_approval_detail_base not found';
    END IF;

    v_original := v_src;

    -- Replace approved filter: include gap/gap_segment in approved_minutes
    -- Old: a->>'activity_type' NOT IN ('lunch', 'gap', 'gap_segment')
    -- New: a->>'activity_type' <> 'lunch'
    v_src := replace(
        v_src,
        'a->>''activity_type'' NOT IN (''lunch'', ''gap'', ''gap_segment'')',
        'a->>''activity_type'' <> ''lunch'''
    );

    -- Replace rejected filter: include gap/gap_segment in rejected_minutes
    -- Old: a->>'activity_type' NOT IN ('gap', 'gap_segment', 'lunch')
    -- New: a->>'activity_type' <> 'lunch'
    v_src := replace(
        v_src,
        'a->>''activity_type'' NOT IN (''gap'', ''gap_segment'', ''lunch'')',
        'a->>''activity_type'' <> ''lunch'''
    );

    IF v_src = v_original THEN
        RAISE NOTICE 'No changes made — patterns not found (may already be patched)';
        RETURN;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Part 1: Patched _get_day_approval_detail_base — gap/gap_segment now included in approved/rejected minutes';
END;
$outer$;

-- ============================================================
-- PART 2: Fix frozen data for all approved days
--         approved_minutes = total_shift_minutes - rejected_minutes
--         (approving a day = accepting all non-rejected time)
-- ============================================================
ALTER TABLE day_approvals DISABLE TRIGGER trg_payroll_lock_day_approvals;

UPDATE day_approvals
SET approved_minutes = total_shift_minutes - rejected_minutes
WHERE status = 'approved'
  AND approved_minutes + rejected_minutes < total_shift_minutes;

ALTER TABLE day_approvals ENABLE TRIGGER trg_payroll_lock_day_approvals;

-- ============================================================
-- PART 3: Patch approve_day to freeze approved = total - rejected
--         Prevents micro-gap discrepancies on future approvals
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

    v_src := replace(
        v_src,
        '-- Upsert day_approvals with frozen values',
        '-- Approving a day means all non-rejected time is approved.
    -- Override the activity-level sum to fill any micro-gaps.
    v_approved_minutes := v_total_shift_minutes - v_rejected_minutes;

    -- Upsert day_approvals with frozen values'
    );

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION approve_day(p_employee_id UUID, p_date DATE, p_notes TEXT DEFAULT NULL) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Part 3: Patched approve_day — approved_minutes = total - rejected on freeze';
END;
$outer$;
