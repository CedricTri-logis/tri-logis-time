-- =============================================================================
-- 123: Fix trip GPS gap computation — filter points by trip time window
-- =============================================================================
-- Bug: compute_gps_gaps uses trip_gps_points to find GPS points for a trip,
-- but detect_trips can link movement points from BEFORE the trip's actual
-- time window (e.g., brief movement episodes during a long stationary cluster).
-- These stale points create phantom gaps of hundreds of minutes on short trips.
--
-- Fix: Add a time filter (started_at - 1min buffer to ended_at + 1min buffer)
-- so only GPS points within the trip's actual time window are considered.
-- Then re-backfill all trips.
-- =============================================================================

CREATE OR REPLACE FUNCTION compute_gps_gaps(p_shift_id UUID)
RETURNS VOID AS $$
DECLARE
    v_cluster RECORD;
    v_trip RECORD;
    v_gap_seconds INTEGER;
    v_gap_count INTEGER;
    v_grace_seconds CONSTANT INTEGER := 300;
BEGIN
    -- Compute gaps for stationary clusters (unchanged)
    FOR v_cluster IN
        SELECT sc.id
        FROM stationary_clusters sc
        WHERE sc.shift_id = p_shift_id
    LOOP
        SELECT
            COALESCE(SUM(GREATEST(0, gap_secs - v_grace_seconds)), 0),
            COALESCE(COUNT(*) FILTER (WHERE gap_secs > v_grace_seconds), 0)
        INTO v_gap_seconds, v_gap_count
        FROM (
            SELECT EXTRACT(EPOCH FROM (
                captured_at - LAG(captured_at) OVER (ORDER BY captured_at)
            ))::INTEGER AS gap_secs
            FROM gps_points
            WHERE stationary_cluster_id = v_cluster.id
        ) gaps
        WHERE gap_secs IS NOT NULL;

        UPDATE stationary_clusters SET
            gps_gap_seconds = v_gap_seconds,
            gps_gap_count = v_gap_count
        WHERE id = v_cluster.id;
    END LOOP;

    -- Compute gaps for trips
    FOR v_trip IN
        SELECT t.id, t.started_at, t.ended_at, t.gps_point_count
        FROM trips t
        WHERE t.shift_id = p_shift_id
    LOOP
        IF v_trip.gps_point_count = 0 THEN
            v_gap_seconds := GREATEST(0,
                EXTRACT(EPOCH FROM (v_trip.ended_at - v_trip.started_at))::INTEGER
                - v_grace_seconds
            );
            v_gap_count := CASE WHEN v_gap_seconds > 0 THEN 1 ELSE 0 END;
        ELSE
            SELECT
                COALESCE(SUM(GREATEST(0, gap_secs - v_grace_seconds)), 0),
                COALESCE(COUNT(*) FILTER (WHERE gap_secs > v_grace_seconds), 0)
            INTO v_gap_seconds, v_gap_count
            FROM (
                SELECT EXTRACT(EPOCH FROM (
                    ts - LAG(ts) OVER (ORDER BY ts)
                ))::INTEGER AS gap_secs
                FROM (
                    SELECT v_trip.started_at AS ts
                    UNION ALL
                    SELECT gp.captured_at
                    FROM gps_points gp
                    JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
                    WHERE tgp.trip_id = v_trip.id
                      AND gp.captured_at >= v_trip.started_at - INTERVAL '1 minute'
                      AND gp.captured_at <= v_trip.ended_at + INTERVAL '1 minute'
                    UNION ALL
                    SELECT v_trip.ended_at
                ) all_times
            ) gaps
            WHERE gap_secs IS NOT NULL;
        END IF;

        UPDATE trips SET
            gps_gap_seconds = v_gap_seconds,
            gps_gap_count = v_gap_count,
            has_gps_gap = (v_trip.gps_point_count = 0)
        WHERE id = v_trip.id;
    END LOOP;
END;
$$ LANGUAGE plpgsql
SET search_path TO public, extensions;

-- =========================================================================
-- Re-backfill all completed shifts
-- =========================================================================
DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts WHERE status = 'completed'
        ORDER BY clocked_in_at
    LOOP
        PERFORM compute_gps_gaps(v_shift.id);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'Re-backfilled GPS gaps for % shifts', v_count;
END $$;
