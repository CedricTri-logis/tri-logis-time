-- Migration: Fix GPS points outside shift boundaries
-- Problem: GPS points captured between shifts get assigned to wrong shift_id,
-- causing overlapping activities in the approval dashboard.
-- Scope: ~3,532 bad GPS points, ~27 bad clusters, ~14 bad trips.

-- ============================================================
-- PART 1: Data cleanup — delete GPS data outside shift windows
-- ============================================================

-- 1a. Delete bad trips first (may reference clusters via start_cluster_id/end_cluster_id)
DELETE FROM trips t
USING shifts s
WHERE s.id = t.shift_id
  AND (t.started_at < s.clocked_in_at - interval '10 minutes'
    OR t.ended_at > s.clocked_out_at + interval '10 minutes');

-- 1b. Delete bad stationary_clusters
DELETE FROM stationary_clusters sc
USING shifts s
WHERE s.id = sc.shift_id
  AND (sc.started_at < s.clocked_in_at - interval '10 minutes'
    OR sc.ended_at > s.clocked_out_at + interval '10 minutes');

-- 1c. Delete bad GPS points
DELETE FROM gps_points gp
USING shifts s
WHERE s.id = gp.shift_id
  AND (gp.captured_at < s.clocked_in_at - interval '10 minutes'
    OR gp.captured_at > s.clocked_out_at + interval '10 minutes');

-- ============================================================
-- PART 2: Prevention trigger — silently drop future bad inserts
-- ============================================================

CREATE OR REPLACE FUNCTION validate_gps_point_shift_boundary()
RETURNS TRIGGER AS $$
DECLARE
    v_clocked_in  TIMESTAMPTZ;
    v_clocked_out TIMESTAMPTZ;
BEGIN
    -- Look up the shift's time window
    SELECT clocked_in_at, clocked_out_at
    INTO v_clocked_in, v_clocked_out
    FROM shifts
    WHERE id = NEW.shift_id;

    -- If shift not found, allow insert (FK constraint will catch invalid shift_id)
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- For active shifts (no clock-out yet), only validate against clock-in
    IF v_clocked_out IS NULL THEN
        IF NEW.captured_at < v_clocked_in - interval '10 minutes' THEN
            RETURN NULL; -- silently drop
        END IF;
        RETURN NEW;
    END IF;

    -- For completed shifts, validate both boundaries
    IF NEW.captured_at < v_clocked_in - interval '10 minutes'
       OR NEW.captured_at > v_clocked_out + interval '10 minutes' THEN
        RETURN NULL; -- silently drop
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER gps_point_shift_boundary_check
    BEFORE INSERT ON gps_points
    FOR EACH ROW
    EXECUTE FUNCTION validate_gps_point_shift_boundary();
