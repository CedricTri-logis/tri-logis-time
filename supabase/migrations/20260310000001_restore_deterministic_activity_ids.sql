-- =============================================================================
-- Restore deterministic activity IDs for stationary_clusters
-- =============================================================================
-- Root cause: Migration 20260309234245 (remove_gps_gap_cluster_reset) rewrote
-- detect_trips but lost the deterministic UUIDs from migration 129.
-- detect_trips uses gen_random_uuid() for clusters, but the mobile app's
-- sync_service.dart calls detect_trips on every sync for completed shifts.
-- Each re-run deletes+recreates clusters with NEW random UUIDs, orphaning any
-- activity_overrides saved by the admin in the approval dashboard.
--
-- Fix: BEFORE INSERT trigger on stationary_clusters that overrides NEW.id with
-- deterministic_activity_id(shift_id, 'cluster', started_at). detect_trips
-- uses RETURNING id INTO v_cluster_id, so the variable correctly captures
-- the trigger-modified deterministic ID.
-- =============================================================================

-- Trigger function: compute deterministic cluster ID
CREATE OR REPLACE FUNCTION set_deterministic_cluster_id()
RETURNS TRIGGER AS $$
BEGIN
    NEW.id := deterministic_activity_id(NEW.shift_id, 'cluster', NEW.started_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop if exists to avoid duplicate
DROP TRIGGER IF EXISTS trg_deterministic_cluster_id ON stationary_clusters;

-- Apply trigger
CREATE TRIGGER trg_deterministic_cluster_id
    BEFORE INSERT ON stationary_clusters
    FOR EACH ROW
    EXECUTE FUNCTION set_deterministic_cluster_id();

-- =============================================================================
-- Cleanup: delete orphaned stop overrides (IDs that don't match any cluster)
-- =============================================================================
DELETE FROM activity_overrides ao
WHERE ao.activity_type = 'stop'
  AND NOT EXISTS (
      SELECT 1 FROM stationary_clusters sc WHERE sc.id = ao.activity_id
  );

-- =============================================================================
-- Re-run detect_trips on shifts from the past 7 days to stabilize cluster IDs.
-- The trigger will auto-assign deterministic IDs to all new inserts.
-- =============================================================================
DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT DISTINCT s.id AS shift_id
        FROM shifts s
        WHERE s.status = 'completed'
          AND s.clocked_in_at >= NOW() - INTERVAL '7 days'
    LOOP
        BEGIN
            PERFORM detect_trips(v_shift.shift_id);
            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'detect_trips failed for shift %: %', v_shift.shift_id, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'Re-ran detect_trips on % shifts (7-day backfill)', v_count;
END;
$$;
