-- =============================================================================
-- Change week boundaries from Monday-Sunday (ISO) to Sunday-Saturday
-- =============================================================================
-- Business requirement: weeks run Sunday to Saturday, not Monday to Sunday.
-- This migration updates the validation in weekly RPCs to accept Sunday
-- instead of Monday as p_week_start.
-- =============================================================================

DO $$
DECLARE
  v_def TEXT;
BEGIN
  -- Fix get_weekly_approval_summary: accept Sunday instead of Monday
  v_def := pg_get_functiondef('public.get_weekly_approval_summary(date)'::regprocedure);
  v_def := replace(v_def, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
  v_def := replace(v_def, 'EXTRACT(ISODOW FROM p_week_start) != 1', 'EXTRACT(DOW FROM p_week_start) != 0');
  v_def := replace(v_def, 'must be a Monday', 'must be a Sunday');
  EXECUTE v_def;

  -- Fix get_weekly_breakdown_totals: accept Sunday instead of Monday
  v_def := pg_get_functiondef('public.get_weekly_breakdown_totals(date)'::regprocedure);
  v_def := replace(v_def, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
  v_def := replace(v_def, 'EXTRACT(ISODOW FROM p_week_start) != 1', 'EXTRACT(DOW FROM p_week_start) != 0');
  v_def := replace(v_def, 'must be a Monday', 'must be a Sunday');
  EXECUTE v_def;
END $$;
