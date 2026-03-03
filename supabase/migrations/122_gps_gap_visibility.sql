-- =============================================================================
-- 122: GPS gap visibility — expose gap metrics on trips and recompute for clusters
-- =============================================================================
-- Previously, stationary_clusters had gps_gap_seconds/gps_gap_count columns (from 087)
-- but gap tracking was removed in migration 113 (always 0). Trips had has_gps_gap
-- boolean but no seconds/count detail.
--
-- This migration:
-- 1. Adds gps_gap_seconds + gps_gap_count columns to trips
-- 2. Creates compute_gps_gaps() function (shared by detect_trips and backfill)
-- 3. Integrates compute_gps_gaps into detect_trips as step 8
-- 4. Updates get_day_approval_detail to read trip gap columns instead of NULL
-- 5. Backfills all completed shifts
-- =============================================================================

-- =========================================================================
-- Part 1: Schema — Add gap columns to trips table
-- =========================================================================
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS gps_gap_seconds INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS gps_gap_count INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN trips.gps_gap_seconds IS 'Total seconds of GPS gaps > 5 min within this trip (excess over 5-min grace period)';
COMMENT ON COLUMN trips.gps_gap_count IS 'Number of individual GPS gaps > 5 min within this trip';

-- =========================================================================
-- Part 2: Create compute_gps_gaps function
-- =========================================================================
CREATE OR REPLACE FUNCTION compute_gps_gaps(p_shift_id UUID)
RETURNS VOID AS $$
DECLARE
    v_cluster RECORD;
    v_trip RECORD;
    v_gap_seconds INTEGER;
    v_gap_count INTEGER;
    v_grace_seconds CONSTANT INTEGER := 300;
BEGIN
    -- Compute gaps for stationary clusters
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
-- Part 3: Redefine detect_trips with PERFORM compute_gps_gaps
-- =========================================================================
CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS TABLE (
    trip_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    start_latitude DECIMAL(10, 8),
    start_longitude DECIMAL(11, 8),
    end_latitude DECIMAL(10, 8),
    end_longitude DECIMAL(11, 8),
    distance_km DECIMAL(8, 3),
    duration_minutes INTEGER,
    confidence_score DECIMAL(3, 2),
    gps_point_count INTEGER
) AS $$
#variable_conflict use_column
DECLARE
    v_shift RECORD;
    v_employee_id UUID;
    v_point RECORD;
    v_prev_point RECORD;

    -- Constants
    v_cluster_radius_m     CONSTANT DECIMAL := 50.0;
    v_cluster_min_duration CONSTANT INTEGER := 3;       -- minutes
    v_max_accuracy         CONSTANT DECIMAL := 200.0;
    v_correction_factor    CONSTANT DECIMAL := 1.3;
    v_min_distance_km      CONSTANT DECIMAL := 0.2;
    v_min_distance_driving CONSTANT DECIMAL := 0.2;
    v_min_displacement_walking CONSTANT DECIMAL := 0.1; -- 100m
    v_gps_gap_minutes      CONSTANT INTEGER := 15;

    -- Current cluster state
    v_cluster_lats DECIMAL[] := '{}';
    v_cluster_lngs DECIMAL[] := '{}';
    v_cluster_accs DECIMAL[] := '{}';
    v_cluster_point_ids UUID[] := '{}';
    v_cluster_started_at TIMESTAMPTZ := NULL;
    v_cluster_last_at TIMESTAMPTZ := NULL;
    v_cluster_confirmed BOOLEAN := FALSE;
    v_cluster_centroid_lat DECIMAL;
    v_cluster_centroid_lng DECIMAL;
    v_cluster_centroid_acc DECIMAL;
    v_cluster_id UUID := NULL;
    v_has_db_cluster BOOLEAN := FALSE;

    -- Incremental centroid running sums: current cluster
    v_acc_val DECIMAL;
    v_csum_lat_w DECIMAL := 0;   -- SUM(lat / GREATEST(acc, 1))
    v_csum_lng_w DECIMAL := 0;   -- SUM(lng / GREATEST(acc, 1))
    v_csum_w DECIMAL := 0;       -- SUM(1 / GREATEST(acc, 1))
    v_csum_inv_acc_sq DECIMAL := 0; -- SUM(1 / GREATEST(acc², 1))

    -- Tentative cluster state
    v_tent_lats DECIMAL[] := '{}';
    v_tent_lngs DECIMAL[] := '{}';
    v_tent_accs DECIMAL[] := '{}';
    v_tent_point_ids UUID[] := '{}';
    v_tent_started_at TIMESTAMPTZ := NULL;
    v_tent_centroid_lat DECIMAL;
    v_tent_centroid_lng DECIMAL;
    v_has_tentative BOOLEAN := FALSE;

    -- Incremental centroid running sums: tentative cluster
    v_tsum_lat_w DECIMAL := 0;
    v_tsum_lng_w DECIMAL := 0;
    v_tsum_w DECIMAL := 0;
    v_tsum_inv_acc_sq DECIMAL := 0;

    -- Transit buffer
    v_transit_point_ids UUID[] := '{}';

    -- Trip tracking
    v_prev_cluster_id UUID := NULL;
    v_prev_trip_end_location_id UUID := NULL;
    v_prev_trip_end_lat DECIMAL;
    v_prev_trip_end_lng DECIMAL;

    -- Distance computations
    v_dist_to_cluster DECIMAL;
    v_dist_to_tent DECIMAL;

    -- For active shift incremental detection
    v_is_active BOOLEAN;
    v_create_clusters BOOLEAN;
    v_cutoff_time TIMESTAMPTZ := NULL;

    -- Trip creation variables
    v_trip_id UUID;
    v_trip_distance DECIMAL;
    v_trip_point_count INTEGER;
    v_trip_low_accuracy INTEGER;
    v_trip_started_at TIMESTAMPTZ;
    v_trip_ended_at TIMESTAMPTZ;
    v_trip_start_lat DECIMAL;
    v_trip_start_lng DECIMAL;
    v_trip_start_acc DECIMAL;
    v_trip_end_lat DECIMAL;
    v_trip_end_lng DECIMAL;
    v_trip_end_acc DECIMAL;
    v_transport_mode TEXT;
    v_displacement DECIMAL;
    v_path_distance DECIMAL;
    v_straightness DECIMAL;
    v_new_cluster_id UUID;
    v_dep_centroid_lat DECIMAL;
    v_dep_centroid_lng DECIMAL;
    v_dep_centroid_acc DECIMAL;
    v_arr_centroid_lat DECIMAL;
    v_arr_centroid_lng DECIMAL;
    v_arr_centroid_acc DECIMAL;
    v_has_prev_point BOOLEAN := FALSE;
BEGIN
    -- =========================================================================
    -- 1. Validate shift and set up incremental mode
    -- =========================================================================
    SELECT s.id, s.employee_id, s.status
    INTO v_shift
    FROM shifts s
    WHERE s.id = p_shift_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shift not found: %', p_shift_id;
    END IF;

    v_employee_id := v_shift.employee_id;
    v_is_active := (v_shift.status = 'active');

    -- =========================================================================
    -- 2. Delete existing data
    -- =========================================================================
    IF v_is_active THEN
        DELETE FROM trips
        WHERE shift_id = p_shift_id
          AND match_status IN ('pending', 'processing');

        SELECT MAX(gp.captured_at) INTO v_cutoff_time
        FROM trips t
        JOIN trip_gps_points tgp ON tgp.trip_id = t.id
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE t.shift_id = p_shift_id;
    ELSE
        DELETE FROM trips WHERE shift_id = p_shift_id;
    END IF;

    v_create_clusters := NOT v_is_active;
    IF v_create_clusters THEN
        DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;
    END IF;

    -- =========================================================================
    -- 3. Main loop
    -- =========================================================================
    v_prev_point := NULL;

    FOR v_point IN
        SELECT
            gp.id,
            gp.latitude,
            gp.longitude,
            gp.accuracy,
            gp.speed,
            gp.captured_at
        FROM gps_points gp
        WHERE gp.shift_id = p_shift_id
          AND (v_cutoff_time IS NULL OR gp.captured_at > v_cutoff_time)
        ORDER BY gp.captured_at ASC
    LOOP
        -- Skip points with poor accuracy
        IF v_point.accuracy IS NOT NULL AND v_point.accuracy > v_max_accuracy THEN
            CONTINUE;
        END IF;

        -- =================================================================
        -- GPS gap check: if > 15 min since prev point AND we have a
        -- confirmed cluster, finalize it and discard tentative state
        -- =================================================================
        IF v_has_prev_point THEN
         IF EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at)) / 60.0 > v_gps_gap_minutes THEN

            IF v_cluster_confirmed THEN
                -- Finalize the confirmed cluster using running sums
                IF v_create_clusters THEN
                    v_cluster_centroid_lat := v_csum_lat_w / v_csum_w;
                    v_cluster_centroid_lng := v_csum_lng_w / v_csum_w;
                    v_cluster_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

                    IF v_has_db_cluster THEN
                        UPDATE stationary_clusters SET
                            centroid_latitude = v_cluster_centroid_lat,
                            centroid_longitude = v_cluster_centroid_lng,
                            centroid_accuracy = v_cluster_centroid_acc,
                            ended_at = v_prev_point.captured_at,
                            duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                            gps_point_count = array_length(v_cluster_point_ids, 1),
                            matched_location_id = COALESCE(
                                match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0)),
                                match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                            )
                        WHERE id = v_cluster_id;
                        UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                        WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                    END IF;
                END IF;

                v_prev_cluster_id := v_cluster_id;
            END IF;

            -- Discard tentative cluster
            IF v_has_tentative THEN
                v_has_tentative := FALSE;
                v_tent_lats := '{}';
                v_tent_lngs := '{}';
                v_tent_accs := '{}';
                v_tent_point_ids := '{}';
                v_tsum_lat_w := 0;
                v_tsum_lng_w := 0;
                v_tsum_w := 0;
                v_tsum_inv_acc_sq := 0;
            END IF;

            -- Reset current cluster for fresh start after gap
            v_cluster_lats := '{}';
            v_cluster_lngs := '{}';
            v_cluster_accs := '{}';
            v_cluster_point_ids := '{}';
            v_cluster_started_at := NULL;
            v_cluster_last_at := NULL;
            v_cluster_confirmed := FALSE;
            v_cluster_id := NULL;
            v_has_db_cluster := FALSE;
            v_transit_point_ids := '{}';
            v_csum_lat_w := 0;
            v_csum_lng_w := 0;
            v_csum_w := 0;
            v_csum_inv_acc_sq := 0;
         END IF;
        END IF;

        -- =================================================================
        -- CORE ALGORITHM
        -- =================================================================

        -- Compute adjusted distance to current cluster centroid (O(1) via running sums)
        IF v_csum_w > 0 THEN
            v_cluster_centroid_lat := v_csum_lat_w / v_csum_w;
            v_cluster_centroid_lng := v_csum_lng_w / v_csum_w;
            v_cluster_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

            v_dist_to_cluster := GREATEST(
                haversine_km(v_cluster_centroid_lat, v_cluster_centroid_lng,
                             v_point.latitude, v_point.longitude) * 1000.0
                - COALESCE(v_point.accuracy, 20.0),
                0
            );
        ELSE
            v_dist_to_cluster := 0;  -- First point, automatically in cluster
        END IF;

        IF v_dist_to_cluster <= v_cluster_radius_m THEN
            -- =============================================================
            -- POINT WITHIN CURRENT CLUSTER
            -- =============================================================
            v_acc_val := COALESCE(v_point.accuracy, 20.0);
            v_cluster_lats := v_cluster_lats || v_point.latitude;
            v_cluster_lngs := v_cluster_lngs || v_point.longitude;
            v_cluster_accs := v_cluster_accs || v_acc_val;
            v_cluster_point_ids := v_cluster_point_ids || v_point.id;
            -- Update running sums
            v_csum_lat_w := v_csum_lat_w + v_point.latitude / GREATEST(v_acc_val, 1);
            v_csum_lng_w := v_csum_lng_w + v_point.longitude / GREATEST(v_acc_val, 1);
            v_csum_w := v_csum_w + 1.0 / GREATEST(v_acc_val, 1);
            v_csum_inv_acc_sq := v_csum_inv_acc_sq + 1.0 / GREATEST(v_acc_val * v_acc_val, 1);

            IF v_cluster_started_at IS NULL THEN
                v_cluster_started_at := v_point.captured_at;
            END IF;
            v_cluster_last_at := v_point.captured_at;

            -- Check if cluster just became confirmed (duration >= 3 min)
            IF NOT v_cluster_confirmed
               AND EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at)) / 60.0 >= v_cluster_min_duration THEN
                v_cluster_confirmed := TRUE;

                IF v_create_clusters THEN
                    -- Centroid from running sums (already includes current point)
                    v_cluster_centroid_lat := v_csum_lat_w / v_csum_w;
                    v_cluster_centroid_lng := v_csum_lng_w / v_csum_w;
                    v_cluster_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

                    INSERT INTO stationary_clusters (
                        shift_id, employee_id,
                        centroid_latitude, centroid_longitude, centroid_accuracy,
                        started_at, ended_at, duration_seconds, gps_point_count,
                        matched_location_id
                    ) VALUES (
                        p_shift_id, v_employee_id,
                        v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc,
                        v_cluster_started_at, v_point.captured_at,
                        EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at))::INTEGER,
                        array_length(v_cluster_point_ids, 1),
                        COALESCE(
                            match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0)),
                            match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                        )
                    )
                    RETURNING id INTO v_cluster_id;
                    v_has_db_cluster := TRUE;

                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids);
                END IF;

            -- NOTE: Removed per-point UPDATE for already-confirmed clusters.
            -- DB updates are deferred to finalization events (GPS gap, tentative
            -- promotion, end-of-data) for O(1) per-point instead of O(m) per-point.
            END IF;

            -- Discard tentative cluster if one exists (point returned to current cluster)
            IF v_has_tentative THEN
                -- Move tentative points to transit buffer
                v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
                v_has_tentative := FALSE;
                v_tent_lats := '{}';
                v_tent_lngs := '{}';
                v_tent_accs := '{}';
                v_tent_point_ids := '{}';
                v_tsum_lat_w := 0;
                v_tsum_lng_w := 0;
                v_tsum_w := 0;
                v_tsum_inv_acc_sq := 0;
            END IF;

        ELSE
            -- =============================================================
            -- POINT BEYOND CURRENT CLUSTER (> 50m adjusted)
            -- =============================================================

            IF NOT v_has_tentative THEN
                -- Start tentative cluster with this point
                v_acc_val := COALESCE(v_point.accuracy, 20.0);
                v_tent_lats := ARRAY[v_point.latitude];
                v_tent_lngs := ARRAY[v_point.longitude];
                v_tent_accs := ARRAY[v_acc_val];
                v_tent_point_ids := ARRAY[v_point.id];
                v_tent_started_at := v_point.captured_at;
                v_has_tentative := TRUE;
                -- Initialize tentative running sums
                v_tsum_lat_w := v_point.latitude / GREATEST(v_acc_val, 1);
                v_tsum_lng_w := v_point.longitude / GREATEST(v_acc_val, 1);
                v_tsum_w := 1.0 / GREATEST(v_acc_val, 1);
                v_tsum_inv_acc_sq := 1.0 / GREATEST(v_acc_val * v_acc_val, 1);

            ELSE
                -- Tentative exists: check distance to tentative centroid (O(1) via running sums)
                v_tent_centroid_lat := v_tsum_lat_w / v_tsum_w;
                v_tent_centroid_lng := v_tsum_lng_w / v_tsum_w;

                v_dist_to_tent := GREATEST(
                    haversine_km(v_tent_centroid_lat, v_tent_centroid_lng,
                                 v_point.latitude, v_point.longitude) * 1000.0
                    - COALESCE(v_point.accuracy, 20.0),
                    0
                );

                IF v_dist_to_tent <= v_cluster_radius_m THEN
                    -- Point within tentative cluster
                    v_acc_val := COALESCE(v_point.accuracy, 20.0);
                    v_tent_lats := v_tent_lats || v_point.latitude;
                    v_tent_lngs := v_tent_lngs || v_point.longitude;
                    v_tent_accs := v_tent_accs || v_acc_val;
                    v_tent_point_ids := v_tent_point_ids || v_point.id;
                    -- Update tentative running sums
                    v_tsum_lat_w := v_tsum_lat_w + v_point.latitude / GREATEST(v_acc_val, 1);
                    v_tsum_lng_w := v_tsum_lng_w + v_point.longitude / GREATEST(v_acc_val, 1);
                    v_tsum_w := v_tsum_w + 1.0 / GREATEST(v_acc_val, 1);
                    v_tsum_inv_acc_sq := v_tsum_inv_acc_sq + 1.0 / GREATEST(v_acc_val * v_acc_val, 1);

                    -- Check if tentative just became confirmed (3 min)
                    IF EXTRACT(EPOCH FROM (v_point.captured_at - v_tent_started_at)) / 60.0 >= v_cluster_min_duration THEN
                        -- ★★★ NEW CLUSTER CONFIRMED ★★★
                        -- Finalize current cluster, create trip, promote tentative

                        -- A) Finalize current cluster
                        IF v_cluster_confirmed THEN
                            -- Departure centroid from running sums
                            v_dep_centroid_lat := v_csum_lat_w / v_csum_w;
                            v_dep_centroid_lng := v_csum_lng_w / v_csum_w;
                            v_dep_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

                            IF v_create_clusters AND v_has_db_cluster THEN
                                UPDATE stationary_clusters SET
                                    centroid_latitude = v_dep_centroid_lat,
                                    centroid_longitude = v_dep_centroid_lng,
                                    centroid_accuracy = v_dep_centroid_acc,
                                    ended_at = v_cluster_last_at,
                                    duration_seconds = EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                                    gps_point_count = array_length(v_cluster_point_ids, 1),
                                    matched_location_id = COALESCE(
                                        match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, COALESCE(v_dep_centroid_acc, 0)),
                                        match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                                    )
                                WHERE id = v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                            END IF;
                            v_prev_cluster_id := v_cluster_id;

                        ELSIF v_csum_w > 0
                              AND v_cluster_started_at IS NOT NULL
                              AND v_cluster_last_at IS NOT NULL
                              AND EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at)) >= v_cluster_min_duration * 60 THEN
                            -- Cluster reached 3 min but wasn't yet confirmed (edge case)
                            v_dep_centroid_lat := v_csum_lat_w / v_csum_w;
                            v_dep_centroid_lng := v_csum_lng_w / v_csum_w;
                            v_dep_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

                            IF v_create_clusters THEN
                                INSERT INTO stationary_clusters (
                                    shift_id, employee_id,
                                    centroid_latitude, centroid_longitude, centroid_accuracy,
                                    started_at, ended_at, duration_seconds, gps_point_count,
                                    matched_location_id
                                ) VALUES (
                                    p_shift_id, v_employee_id,
                                    v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc,
                                    v_cluster_started_at, v_cluster_last_at,
                                    EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                                    array_length(v_cluster_point_ids, 1),
                                    COALESCE(
                                        match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, COALESCE(v_dep_centroid_acc, 0)),
                                        match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                                    )
                                )
                                RETURNING id INTO v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids);
                            END IF;
                            v_prev_cluster_id := v_cluster_id;
                        ELSE
                            -- Current cluster too short — compute centroid for trip coords
                            IF v_csum_w > 0 THEN
                                v_dep_centroid_lat := v_csum_lat_w / v_csum_w;
                                v_dep_centroid_lng := v_csum_lng_w / v_csum_w;
                                v_dep_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);
                            END IF;
                        END IF;

                        -- B) Compute arrival (tentative) centroid from running sums
                        v_arr_centroid_lat := v_tsum_lat_w / v_tsum_w;
                        v_arr_centroid_lng := v_tsum_lng_w / v_tsum_w;
                        v_arr_centroid_acc := 1.0 / SQRT(v_tsum_inv_acc_sq);

                        -- C) Persist tentative as new cluster
                        IF v_create_clusters THEN
                            INSERT INTO stationary_clusters (
                                shift_id, employee_id,
                                centroid_latitude, centroid_longitude, centroid_accuracy,
                                started_at, ended_at, duration_seconds, gps_point_count,
                                matched_location_id
                            ) VALUES (
                                p_shift_id, v_employee_id,
                                v_arr_centroid_lat, v_arr_centroid_lng, v_arr_centroid_acc,
                                v_tent_started_at, v_point.captured_at,
                                EXTRACT(EPOCH FROM (v_point.captured_at - v_tent_started_at))::INTEGER,
                                array_length(v_tent_point_ids, 1),
                                COALESCE(
                                    match_trip_to_location(v_arr_centroid_lat, v_arr_centroid_lng, COALESCE(v_arr_centroid_acc, 0)),
                                    match_cluster_by_point_voting(v_tent_lats::DOUBLE PRECISION[], v_tent_lngs::DOUBLE PRECISION[], v_tent_accs::DOUBLE PRECISION[])
                                )
                            )
                            RETURNING id INTO v_new_cluster_id;

                            UPDATE gps_points SET stationary_cluster_id = v_new_cluster_id
                            WHERE id = ANY(v_tent_point_ids);
                        ELSE
                            v_new_cluster_id := NULL;  -- Active shifts: use NULL to avoid FK violation
                        END IF;

                        -- D) Create trip from departure cluster to arrival cluster
                        v_trip_start_lat := COALESCE(v_dep_centroid_lat, v_cluster_centroid_lat);
                        v_trip_start_lng := COALESCE(v_dep_centroid_lng, v_cluster_centroid_lng);
                        v_trip_start_acc := COALESCE(v_dep_centroid_acc, v_cluster_centroid_acc, 0);
                        v_trip_end_lat := v_arr_centroid_lat;
                        v_trip_end_lng := v_arr_centroid_lng;
                        v_trip_end_acc := COALESCE(v_arr_centroid_acc, 0);

                        v_trip_distance := haversine_km(
                            v_trip_start_lat, v_trip_start_lng,
                            v_trip_end_lat, v_trip_end_lng
                        ) * v_correction_factor;

                        v_trip_point_count := COALESCE(array_length(v_transit_point_ids, 1), 0);
                        v_trip_low_accuracy := 0;
                        IF v_trip_point_count > 0 THEN
                            SELECT COUNT(*) INTO v_trip_low_accuracy
                            FROM gps_points
                            WHERE id = ANY(v_transit_point_ids)
                              AND accuracy > 50;
                        END IF;

                        -- Trip timing: departure cluster end → arrival cluster start
                        v_trip_started_at := COALESCE(v_cluster_last_at, v_cluster_started_at);
                        v_trip_ended_at := v_tent_started_at;

                        -- Min distance check
                        IF v_trip_distance >= v_min_distance_km THEN
                            v_trip_id := gen_random_uuid();
                            INSERT INTO trips (
                                id, shift_id, employee_id,
                                started_at, ended_at,
                                start_latitude, start_longitude,
                                end_latitude, end_longitude,
                                distance_km, duration_minutes,
                                classification, confidence_score,
                                gps_point_count, low_accuracy_segments,
                                detection_method, transport_mode,
                                start_cluster_id, end_cluster_id
                            ) VALUES (
                                v_trip_id, p_shift_id, v_employee_id,
                                v_trip_started_at, v_trip_ended_at,
                                v_trip_start_lat, v_trip_start_lng,
                                v_trip_end_lat, v_trip_end_lng,
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                'business',
                                ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                v_trip_point_count,
                                v_trip_low_accuracy,
                                'auto',
                                'unknown',
                                v_prev_cluster_id,
                                v_new_cluster_id
                            );

                            -- Insert trip GPS points (transit buffer)
                            IF v_trip_point_count > 0 THEN
                                FOR i IN 1..v_trip_point_count LOOP
                                    INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                                    VALUES (v_trip_id, v_transit_point_ids[i], i)
                                    ON CONFLICT DO NOTHING;
                                END LOOP;
                            END IF;

                            -- Post-processing: classify transport mode
                            v_transport_mode := classify_trip_transport_mode(v_trip_id);

                            -- Ghost trip filters
                            v_displacement := haversine_km(
                                v_trip_start_lat, v_trip_start_lng,
                                v_trip_end_lat, v_trip_end_lng
                            );

                            -- Compute cumulative path distance from transit GPS points
                            -- (handles cases where A→far→B with A near B, e.g. round-ish trips)
                            v_path_distance := v_trip_distance;
                            IF v_trip_point_count > 1 THEN
                                SELECT COALESCE(SUM(seg_km), 0) INTO v_path_distance
                                FROM (
                                    SELECT haversine_km(
                                        latitude, longitude,
                                        LEAD(latitude) OVER (ORDER BY captured_at),
                                        LEAD(longitude) OVER (ORDER BY captured_at)
                                    ) as seg_km
                                    FROM gps_points
                                    WHERE id = ANY(v_transit_point_ids)
                                ) segs
                                WHERE seg_km IS NOT NULL;
                            END IF;

                            IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND GREATEST(v_trip_distance, v_path_distance) < v_min_distance_driving THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND v_displacement < 0.05 THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND v_trip_point_count <= 10 AND v_trip_point_count > 0 THEN
                                v_straightness := v_displacement / NULLIF(v_trip_distance, 0);
                                IF v_straightness IS NOT NULL AND v_straightness < 0.10 THEN
                                    DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                    DELETE FROM trips WHERE id = v_trip_id;
                                ELSE
                                    -- Trip passed all filters
                                    UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                                    -- Location matching
                                    UPDATE trips SET
                                        start_location_id = CASE
                                            WHEN v_prev_trip_end_location_id IS NOT NULL
                                                 AND haversine_km(v_trip_start_lat, v_trip_start_lng,
                                                                  v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                            THEN v_prev_trip_end_location_id
                                            ELSE match_trip_to_location(v_trip_start_lat, v_trip_start_lng, v_trip_start_acc)
                                        END,
                                        end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                    WHERE id = v_trip_id;

                                    SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                                    v_prev_trip_end_lat := v_trip_end_lat;
                                    v_prev_trip_end_lng := v_trip_end_lng;

                                    RETURN QUERY SELECT
                                        v_trip_id,
                                        v_trip_started_at,
                                        v_trip_ended_at,
                                        v_trip_start_lat::DECIMAL(10,8),
                                        v_trip_start_lng::DECIMAL(11,8),
                                        v_trip_end_lat::DECIMAL(10,8),
                                        v_trip_end_lng::DECIMAL(11,8),
                                        ROUND(v_trip_distance, 3),
                                        GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                        ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                        v_trip_point_count;
                                END IF;
                            ELSE
                                -- Trip passed all filters (non-driving or driving with >10 pts)
                                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                                -- Location matching
                                UPDATE trips SET
                                    start_location_id = CASE
                                        WHEN v_prev_trip_end_location_id IS NOT NULL
                                             AND haversine_km(v_trip_start_lat, v_trip_start_lng,
                                                              v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                        THEN v_prev_trip_end_location_id
                                        ELSE match_trip_to_location(v_trip_start_lat, v_trip_start_lng, v_trip_start_acc)
                                    END,
                                    end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                WHERE id = v_trip_id;

                                SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                                v_prev_trip_end_lat := v_trip_end_lat;
                                v_prev_trip_end_lng := v_trip_end_lng;

                                RETURN QUERY SELECT
                                    v_trip_id,
                                    v_trip_started_at,
                                    v_trip_ended_at,
                                    v_trip_start_lat::DECIMAL(10,8),
                                    v_trip_start_lng::DECIMAL(11,8),
                                    v_trip_end_lat::DECIMAL(10,8),
                                    v_trip_end_lng::DECIMAL(11,8),
                                    ROUND(v_trip_distance, 3),
                                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                    ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                    v_trip_point_count;
                            END IF;
                        END IF;

                        -- E) Promote: tentative becomes current
                        v_cluster_lats := v_tent_lats;
                        v_cluster_lngs := v_tent_lngs;
                        v_cluster_accs := v_tent_accs;
                        v_cluster_point_ids := v_tent_point_ids;
                        v_cluster_started_at := v_tent_started_at;
                        v_cluster_last_at := v_point.captured_at;
                        v_cluster_confirmed := TRUE;
                        v_cluster_centroid_lat := v_arr_centroid_lat;
                        v_cluster_centroid_lng := v_arr_centroid_lng;
                        v_cluster_centroid_acc := v_arr_centroid_acc;
                        v_cluster_id := v_new_cluster_id;
                        v_has_db_cluster := v_create_clusters;
                        v_prev_cluster_id := v_new_cluster_id;
                        -- Copy tentative running sums to current
                        v_csum_lat_w := v_tsum_lat_w;
                        v_csum_lng_w := v_tsum_lng_w;
                        v_csum_w := v_tsum_w;
                        v_csum_inv_acc_sq := v_tsum_inv_acc_sq;

                        -- Reset tentative and transit
                        v_has_tentative := FALSE;
                        v_tent_lats := '{}';
                        v_tent_lngs := '{}';
                        v_tent_accs := '{}';
                        v_tent_point_ids := '{}';
                        v_transit_point_ids := '{}';
                        v_tsum_lat_w := 0;
                        v_tsum_lng_w := 0;
                        v_tsum_w := 0;
                        v_tsum_inv_acc_sq := 0;
                    END IF;

                ELSE
                    -- Point beyond BOTH clusters → in transit
                    -- Move tentative points to transit buffer
                    v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
                    -- Also add this point to transit
                    v_transit_point_ids := v_transit_point_ids || v_point.id;

                    -- Start new tentative with this point
                    v_acc_val := COALESCE(v_point.accuracy, 20.0);
                    v_tent_lats := ARRAY[v_point.latitude];
                    v_tent_lngs := ARRAY[v_point.longitude];
                    v_tent_accs := ARRAY[v_acc_val];
                    v_tent_point_ids := ARRAY[v_point.id];
                    v_tent_started_at := v_point.captured_at;
                    -- Reset tentative running sums for new point
                    v_tsum_lat_w := v_point.latitude / GREATEST(v_acc_val, 1);
                    v_tsum_lng_w := v_point.longitude / GREATEST(v_acc_val, 1);
                    v_tsum_w := 1.0 / GREATEST(v_acc_val, 1);
                    v_tsum_inv_acc_sq := 1.0 / GREATEST(v_acc_val * v_acc_val, 1);
                END IF;
            END IF;
        END IF;

        v_prev_point := v_point;
        v_has_prev_point := TRUE;
    END LOOP;

    -- =========================================================================
    -- 5. End of data: finalize last cluster
    -- =========================================================================
    IF NOT v_is_active THEN
        -- Finalize the current cluster if it qualifies
        IF v_cluster_confirmed OR (
            v_csum_w > 0
            AND v_cluster_started_at IS NOT NULL
            AND v_cluster_last_at IS NOT NULL
            AND EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at)) >= v_cluster_min_duration * 60
        ) THEN
            IF v_create_clusters THEN
                v_cluster_centroid_lat := v_csum_lat_w / v_csum_w;
                v_cluster_centroid_lng := v_csum_lng_w / v_csum_w;
                v_cluster_centroid_acc := 1.0 / SQRT(v_csum_inv_acc_sq);

                IF v_has_db_cluster THEN
                    UPDATE stationary_clusters SET
                        centroid_latitude = v_cluster_centroid_lat,
                        centroid_longitude = v_cluster_centroid_lng,
                        centroid_accuracy = v_cluster_centroid_acc,
                        ended_at = v_cluster_last_at,
                        duration_seconds = EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                        gps_point_count = array_length(v_cluster_point_ids, 1),
                        matched_location_id = COALESCE(
                            match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0)),
                            match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                        )
                    WHERE id = v_cluster_id;
                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                ELSE
                    INSERT INTO stationary_clusters (
                        shift_id, employee_id,
                        centroid_latitude, centroid_longitude, centroid_accuracy,
                        started_at, ended_at, duration_seconds, gps_point_count,
                        matched_location_id
                    ) VALUES (
                        p_shift_id, v_employee_id,
                        v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc,
                        v_cluster_started_at, v_cluster_last_at,
                        EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                        array_length(v_cluster_point_ids, 1),
                        COALESCE(
                            match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0)),
                            match_cluster_by_point_voting(v_cluster_lats::DOUBLE PRECISION[], v_cluster_lngs::DOUBLE PRECISION[], v_cluster_accs::DOUBLE PRECISION[])
                        )
                    )
                    RETURNING id INTO v_cluster_id;
                    v_has_db_cluster := TRUE;
                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids);
                END IF;
            END IF;
            v_prev_cluster_id := v_cluster_id;
        END IF;

        -- =====================================================================
        -- 6. Handle trailing transit (points after last confirmed cluster)
        -- =====================================================================
        IF v_prev_cluster_id IS NOT NULL AND v_has_prev_point THEN
            -- Collect all trailing points (transit + tentative)
            IF v_has_tentative THEN
                v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
            END IF;

            v_trip_point_count := COALESCE(array_length(v_transit_point_ids, 1), 0);

            IF v_trip_point_count > 0 THEN
                -- Get departure cluster centroid
                SELECT centroid_latitude, centroid_longitude, COALESCE(centroid_accuracy, 0)
                INTO v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc
                FROM stationary_clusters WHERE id = v_prev_cluster_id;

                IF v_dep_centroid_lat IS NOT NULL THEN
                    -- Use last transit/tentative point as arrival
                    v_trip_end_lat := v_prev_point.latitude;
                    v_trip_end_lng := v_prev_point.longitude;
                    v_trip_end_acc := COALESCE(v_prev_point.accuracy, 0);

                    v_trip_distance := haversine_km(
                        v_dep_centroid_lat, v_dep_centroid_lng,
                        v_trip_end_lat, v_trip_end_lng
                    ) * v_correction_factor;

                    -- Get departure cluster end time for trip start
                    SELECT ended_at INTO v_trip_started_at
                    FROM stationary_clusters WHERE id = v_prev_cluster_id;
                    v_trip_ended_at := v_prev_point.captured_at;

                    v_trip_low_accuracy := 0;
                    SELECT COUNT(*) INTO v_trip_low_accuracy
                    FROM gps_points
                    WHERE id = ANY(v_transit_point_ids)
                      AND accuracy > 50;

                    IF v_trip_distance >= v_min_distance_km THEN
                        v_trip_id := gen_random_uuid();
                        INSERT INTO trips (
                            id, shift_id, employee_id,
                            started_at, ended_at,
                            start_latitude, start_longitude,
                            end_latitude, end_longitude,
                            distance_km, duration_minutes,
                            classification, confidence_score,
                            gps_point_count, low_accuracy_segments,
                            detection_method, transport_mode,
                            start_cluster_id, end_cluster_id
                        ) VALUES (
                            v_trip_id, p_shift_id, v_employee_id,
                            v_trip_started_at, v_trip_ended_at,
                            v_dep_centroid_lat, v_dep_centroid_lng,
                            v_trip_end_lat, v_trip_end_lng,
                            ROUND(v_trip_distance, 3),
                            GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                            'business',
                            ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                            v_trip_point_count,
                            v_trip_low_accuracy,
                            'auto',
                            'unknown',
                            v_prev_cluster_id,
                            NULL
                        );

                        FOR i IN 1..v_trip_point_count LOOP
                            INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                            VALUES (v_trip_id, v_transit_point_ids[i], i)
                            ON CONFLICT DO NOTHING;
                        END LOOP;

                        -- Post-processing
                        v_transport_mode := classify_trip_transport_mode(v_trip_id);
                        v_displacement := haversine_km(
                            v_dep_centroid_lat, v_dep_centroid_lng,
                            v_trip_end_lat, v_trip_end_lng
                        );

                        -- Compute cumulative path distance from transit GPS points
                        v_path_distance := v_trip_distance;
                        IF v_trip_point_count > 1 THEN
                            SELECT COALESCE(SUM(seg_km), 0) INTO v_path_distance
                            FROM (
                                SELECT haversine_km(
                                    latitude, longitude,
                                    LEAD(latitude) OVER (ORDER BY captured_at),
                                    LEAD(longitude) OVER (ORDER BY captured_at)
                                ) as seg_km
                                FROM gps_points
                                WHERE id = ANY(v_transit_point_ids)
                            ) segs
                            WHERE seg_km IS NOT NULL;
                        END IF;

                        IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND GREATEST(v_trip_distance, v_path_distance) < v_min_distance_driving THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_displacement < 0.05 THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_trip_point_count <= 10 THEN
                            v_straightness := v_displacement / NULLIF(v_trip_distance, 0);
                            IF v_straightness IS NOT NULL AND v_straightness < 0.10 THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSE
                                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;
                                UPDATE trips SET
                                    start_location_id = CASE
                                        WHEN v_prev_trip_end_location_id IS NOT NULL
                                             AND haversine_km(v_dep_centroid_lat, v_dep_centroid_lng,
                                                              v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                        THEN v_prev_trip_end_location_id
                                        ELSE match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc)
                                    END,
                                    end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                WHERE id = v_trip_id;

                                RETURN QUERY SELECT
                                    v_trip_id, v_trip_started_at, v_trip_ended_at,
                                    v_dep_centroid_lat::DECIMAL(10,8), v_dep_centroid_lng::DECIMAL(11,8),
                                    v_trip_end_lat::DECIMAL(10,8), v_trip_end_lng::DECIMAL(11,8),
                                    ROUND(v_trip_distance, 3),
                                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                    ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                    v_trip_point_count;
                            END IF;
                        ELSE
                            UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;
                            UPDATE trips SET
                                start_location_id = CASE
                                    WHEN v_prev_trip_end_location_id IS NOT NULL
                                         AND haversine_km(v_dep_centroid_lat, v_dep_centroid_lng,
                                                          v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                    THEN v_prev_trip_end_location_id
                                    ELSE match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc)
                                END,
                                end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                            WHERE id = v_trip_id;

                            RETURN QUERY SELECT
                                v_trip_id, v_trip_started_at, v_trip_ended_at,
                                v_dep_centroid_lat::DECIMAL(10,8), v_dep_centroid_lng::DECIMAL(11,8),
                                v_trip_end_lat::DECIMAL(10,8), v_trip_end_lng::DECIMAL(11,8),
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                v_trip_point_count;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END IF;
    END IF;

    -- =========================================================================
    -- 7. Post-processing: compute effective location types for clusters
    -- =========================================================================
    IF v_create_clusters THEN
        PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);
    END IF;

    -- =========================================================================
    -- 8. Post-processing: compute GPS gap metrics for clusters and trips
    -- =========================================================================
    PERFORM compute_gps_gaps(p_shift_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO public, extensions;

-- =========================================================================
-- Part 4: Redefine get_day_approval_detail (trip gaps from columns)
-- =========================================================================
CREATE OR REPLACE FUNCTION get_day_approval_detail(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
BEGIN
    -- Check for active shifts on this day
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'active'
    ) INTO v_has_active_shift;

    -- Get existing day_approval if any
    SELECT * INTO v_day_approval
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- If already approved, return frozen data
    IF v_day_approval.status = 'approved' THEN
        NULL; -- Fall through to activity building
    END IF;

    -- Calculate total shift minutes for completed shifts on this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    -- Build classified activity list
    WITH activity_data AS (
        -- STOPS
        SELECT
            'stop'::TEXT AS activity_type,
            sc.id AS activity_id,
            sc.shift_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            sc.matched_location_id,
            l.name AS location_name,
            l.location_type::TEXT AS location_type,
            sc.centroid_latitude AS latitude,
            sc.centroid_longitude AS longitude,
            sc.gps_gap_seconds,
            sc.gps_gap_count,
            CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN sc.matched_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                WHEN sc.matched_location_id IS NULL THEN 'Lieu inconnu'
                ELSE 'Lieu inconnu'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180

        UNION ALL

        -- TRIPS (with cluster-based location fallback)
        SELECT
            'trip'::TEXT,
            t.id,
            t.shift_id,
            t.started_at,
            t.ended_at,
            t.duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            t.start_latitude AS latitude,
            t.start_longitude AS longitude,
            t.gps_gap_seconds,
            t.gps_gap_count,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'approved'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'Déplacement professionnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'Destination inconnue'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('vendor', 'gaz')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('vendor', 'gaz') THEN 'Trajet fournisseur/station (à vérifier)'
                ELSE 'À vérifier'
            END,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            COALESCE(t.start_location_id, dep_cluster.matched_location_id),
            COALESCE(sl.name, dep_loc.name)::TEXT AS start_location_name,
            COALESCE(sl.location_type, dep_loc.location_type)::TEXT AS start_location_type,
            COALESCE(t.end_location_id, arr_cluster.matched_location_id),
            COALESCE(el.name, arr_loc.name)::TEXT AS end_location_name,
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id
            FROM stationary_clusters sc2
            WHERE sc2.employee_id = p_employee_id
              AND sc2.ended_at = t.started_at
            LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id
            FROM stationary_clusters sc3
            WHERE sc3.employee_id = p_employee_id
              AND sc3.started_at = t.ended_at
            LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ

        UNION ALL

        -- CLOCK IN
        SELECT
            'clock_in'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_in_at,
            s.clocked_in_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL,
            (s.clock_in_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu inconnu'
                ELSE 'Clock-in lieu inconnu'
            END,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_in_location IS NOT NULL
              AND ST_DWithin(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                GREATEST(l.radius_meters, COALESCE(s.clock_in_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) ci_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_in_location IS NOT NULL

        UNION ALL

        -- CLOCK OUT
        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at,
            s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu inconnu'
                ELSE 'Clock-out lieu inconnu'
            END,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_out_location IS NOT NULL
              AND ST_DWithin(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                GREATEST(l.radius_meters, COALESCE(s.clock_out_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) co_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_out_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
    ),
    classified AS (
        SELECT
            ad.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, ad.auto_status) AS final_status
        FROM activity_data ad
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
           AND ao.activity_type = ad.activity_type
           AND ao.activity_id = ad.activity_id
        ORDER BY ad.started_at ASC
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', c.activity_type,
            'activity_id', c.activity_id,
            'shift_id', c.shift_id,
            'started_at', c.started_at,
            'ended_at', c.ended_at,
            'duration_minutes', c.duration_minutes,
            'auto_status', c.auto_status,
            'auto_reason', c.auto_reason,
            'override_status', c.override_status,
            'override_reason', c.override_reason,
            'final_status', c.final_status,
            'matched_location_id', c.matched_location_id,
            'location_name', c.location_name,
            'location_type', c.location_type,
            'latitude', c.latitude,
            'longitude', c.longitude,
            'distance_km', c.distance_km,
            'transport_mode', c.transport_mode,
            'has_gps_gap', c.has_gps_gap,
            'start_location_id', c.start_location_id,
            'start_location_name', c.start_location_name,
            'start_location_type', c.start_location_type,
            'end_location_id', c.end_location_id,
            'end_location_name', c.end_location_name,
            'end_location_type', c.end_location_type,
            'gps_gap_seconds', c.gps_gap_seconds,
            'gps_gap_count', c.gps_gap_count
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- Compute summary from activities JSONB
    -- For needs_review_count, exclude clock events that overlap with a stop (±60s tolerance)
    -- These are "merged" on the frontend and invisible to the admin
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE
            a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' = 'stop'
                      AND (a->>'started_at')::TIMESTAMPTZ >= ((s->>'started_at')::TIMESTAMPTZ - INTERVAL '60 seconds')
                      AND (a->>'started_at')::TIMESTAMPTZ <= ((s->>'ended_at')::TIMESTAMPTZ + INTERVAL '60 seconds')
                )
            )
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen values for summary
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    -- Build result
    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'approval_status', COALESCE(v_day_approval.status, 'pending'),
        'approved_by', v_day_approval.approved_by,
        'approved_at', v_day_approval.approved_at,
        'notes', v_day_approval.notes,
        'activities', COALESCE(v_activities, '[]'::JSONB),
        'summary', jsonb_build_object(
            'total_shift_minutes', v_total_shift_minutes,
            'approved_minutes', v_approved_minutes,
            'rejected_minutes', v_rejected_minutes,
            'needs_review_count', v_needs_review_count
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =========================================================================
-- Part 5: Backfill all completed shifts
-- =========================================================================
DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts
        WHERE status = 'completed'
        ORDER BY clocked_in_at DESC
    LOOP
        PERFORM compute_gps_gaps(v_shift.id);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'Backfilled GPS gaps for % shifts', v_count;
END $$;
