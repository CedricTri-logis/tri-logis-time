-- ============================================================
-- Migration: Fix gap detection excluding valid clusters/trips
--
-- Bug: The activity_evts CTE in _get_day_approval_detail_base
-- uses time-based matching with a 1-minute tolerance to join
-- stationary_clusters and trips to shift_boundaries:
--
--   sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
--
-- When a cluster starts >1 minute before the shift's clock-in
-- (e.g. GPS points captured before the employee taps clock-in),
-- the cluster is excluded from coverage events. The gap detector
-- then thinks the entire shift has NO activities and generates a
-- full-shift "Temps non suivi" gap — even though the cluster has
-- hundreds of GPS points with zero gaps.
--
-- Example: Karo-Lyn Fauchon 2026-03-27, shift 75b12211:
--   Cluster started at 13:37:37 UTC (2m42s before clock-in at 13:40:19)
--   653 GPS points, 0 gps_gap_seconds — GPS was perfect
--   But the 1-minute tolerance excluded it → 257 min phantom gap
--
-- Fix: Replace time-based matching with shift_id joins for both
-- clusters and trips. The shift_id FK is authoritative — it was
-- set when detect_trips() processed the shift. The main activity
-- query already uses shift_id correctly; only the gap detection
-- activity_evts CTE used time-based matching.
-- ============================================================

DO $outer$
DECLARE
    v_src TEXT;
    v_old_clusters TEXT;
    v_new_clusters TEXT;
    v_old_trips TEXT;
    v_new_trips TEXT;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    IF v_src IS NULL THEN
        RAISE NOTICE 'Function _get_day_approval_detail_base not found, skipping';
        RETURN;
    END IF;

    -- ============================================================
    -- Fix 1: Stationary clusters — replace time-based with shift_id
    -- ============================================================
    v_old_clusters := 'JOIN stationary_clusters sc
            ON sc.employee_id = p_employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''
           AND sc.started_at < sb.clocked_out_at
           AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180';

    v_new_clusters := 'JOIN stationary_clusters sc
            ON sc.shift_id = sb.shift_id
           AND sc.duration_seconds >= 180';

    IF v_src NOT LIKE '%' || v_old_clusters || '%' THEN
        RAISE NOTICE 'Cluster pattern not found (may already be patched), skipping cluster fix';
    ELSE
        v_src := replace(v_src, v_old_clusters, v_new_clusters);
        RAISE NOTICE 'Patched: stationary_clusters now joined by shift_id';
    END IF;

    -- ============================================================
    -- Fix 2: Trips — replace time-based with shift_id
    -- ============================================================
    v_old_trips := 'JOIN trips t
            ON t.employee_id = p_employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''
           AND t.started_at < sb.clocked_out_at
           AND t.ended_at > sb.clocked_in_at';

    v_new_trips := 'JOIN trips t
            ON t.shift_id = sb.shift_id';

    IF v_src NOT LIKE '%' || v_old_trips || '%' THEN
        RAISE NOTICE 'Trip pattern not found (may already be patched), skipping trip fix';
    ELSE
        v_src := replace(v_src, v_old_trips, v_new_trips);
        RAISE NOTICE 'Patched: trips now joined by shift_id';
    END IF;

    -- Apply the patched function
    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Successfully patched _get_day_approval_detail_base: gap detection now uses shift_id joins';
END;
$outer$;
