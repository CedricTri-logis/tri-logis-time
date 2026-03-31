-- ============================================================
-- Migration: Fix save_activity_override missing 'manual_time' type
--
-- Bug: save_activity_override does not accept 'manual_time' as a
-- valid activity_type. Manual time entries are returned by
-- _get_day_approval_detail_base with auto_status = 'needs_review',
-- but supervisors cannot approve/reject them because the override
-- RPC rejects the activity type.
--
-- Root cause: A later migration recreated save_activity_override
-- without including 'manual_time' in the validation list.
-- remove_activity_override and _get_day_approval_detail_base
-- already have it correctly.
--
-- Fix: Patch the validation list to include 'manual_time'.
-- ============================================================

DO $patch$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'save_activity_override'
      AND pronamespace = 'public'::regnamespace;

    IF v_funcdef IS NULL THEN
        RAISE EXCEPTION 'save_activity_override not found';
    END IF;

    -- Check if already fixed
    IF v_funcdef LIKE '%manual_time%' THEN
        RAISE NOTICE 'save_activity_override already includes manual_time, skipping';
        RETURN;
    END IF;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Add 'manual_time' to the validation list
    v_funcdef := replace(
        v_funcdef,
        $$'stop_segment', 'trip_segment', 'gap_segment', 'lunch_segment'$$,
        $$'stop_segment', 'trip_segment', 'gap_segment', 'lunch_segment', 'manual_time'$$
    );

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched save_activity_override: added manual_time to valid activity types';
END;
$patch$;
