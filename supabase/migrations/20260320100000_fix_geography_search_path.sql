-- =============================================================================
-- Fix search_path for all functions that use PostGIS geography type
-- =============================================================================
-- PostGIS is installed in the extensions schema. Functions with
-- SET search_path = public (without extensions) fail with:
--   "type geography does not exist"
-- This migration ensures ALL functions that use geography (directly or
-- via calling get_day_approval_detail → _get_day_approval_detail_base)
-- include extensions in their search_path.
-- =============================================================================

-- _get_day_approval_detail_base: directly uses ::geography
ALTER FUNCTION _get_day_approval_detail_base(UUID, DATE)
    SET search_path = public, extensions;

-- get_day_approval_detail: wrapper that calls _get_day_approval_detail_base
ALTER FUNCTION get_day_approval_detail(UUID, DATE)
    SET search_path = public, extensions;

-- segment_activity: calls get_day_approval_detail
ALTER FUNCTION segment_activity(TEXT, UUID, TIMESTAMPTZ[], UUID, TIMESTAMPTZ, TIMESTAMPTZ)
    SET search_path = public, extensions;

-- unsegment_activity: calls get_day_approval_detail
ALTER FUNCTION unsegment_activity(TEXT, UUID)
    SET search_path = public, extensions;

-- get_weekly_approval_summary: uses geography indirectly
ALTER FUNCTION get_weekly_approval_summary(DATE)
    SET search_path = public, extensions;

-- save_activity_override: calls get_day_approval_detail
ALTER FUNCTION save_activity_override(UUID, DATE, TEXT, UUID, TEXT, TEXT)
    SET search_path = public, extensions;

-- remove_activity_override: calls get_day_approval_detail
ALTER FUNCTION remove_activity_override(UUID, DATE, TEXT, UUID)
    SET search_path = public, extensions;

-- approve_day: calls get_day_approval_detail
ALTER FUNCTION approve_day(UUID, DATE, TEXT)
    SET search_path = public, extensions;

-- edit_shift_time: calls get_day_approval_detail
DO $$ BEGIN
    ALTER FUNCTION edit_shift_time(UUID, TIMESTAMPTZ, TIMESTAMPTZ)
        SET search_path = public, extensions;
EXCEPTION WHEN undefined_function THEN NULL;
END $$;

-- get_weekly_breakdown_totals: may use geography
DO $$ BEGIN
    ALTER FUNCTION get_weekly_breakdown_totals(DATE)
        SET search_path = public, extensions;
EXCEPTION WHEN undefined_function THEN NULL;
END $$;
