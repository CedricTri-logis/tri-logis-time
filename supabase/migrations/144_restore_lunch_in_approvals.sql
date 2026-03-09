-- =============================================================================
-- 144: Restore lunch break support in approval functions
-- =============================================================================
-- Migration 143 (commute_trip_auto_rejection) overwrote both
-- get_day_approval_detail and get_weekly_approval_summary without the
-- lunch break changes from migrations 132/133/136.
-- This migration re-adds lunch_minutes to both functions while keeping
-- the commute detection and anomaly detection from 143.
-- =============================================================================

-- =========================================================================
-- 1. Fix get_day_approval_detail — add lunch breaks back
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
    v_lunch_minutes INTEGER := 0;
BEGIN
    -- Check for active shifts on this day
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND to_business_date(clocked_in_at) = p_date
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
      AND to_business_date(clocked_in_at) = p_date
      AND status = 'completed';

    -- Calculate lunch minutes for this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60
    ), 0)
    INTO v_lunch_minutes
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.ended_at IS NOT NULL
      AND to_business_date(lb.started_at) = p_date;

    -- Subtract lunch from total shift minutes
    v_total_shift_minutes := GREATEST(v_total_shift_minutes - v_lunch_minutes, 0);

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
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (a verifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (a verifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Cafe / Restaurant'
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
          AND sc.started_at >= business_day_start(p_date)
          AND sc.started_at < business_day_end(p_date)
          AND sc.duration_seconds >= 180

        UNION ALL

        -- TRIPS (with anomaly detection + commute detection from migration 143)
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
            -- auto_status with anomaly detection + commute detection
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
                    CASE
                        WHEN t.expected_distance_km IS NOT NULL
                         AND t.distance_km > 2.0 * t.expected_distance_km THEN 'needs_review'
                        WHEN t.expected_duration_seconds IS NOT NULL
                         AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0) THEN 'needs_review'
                        ELSE 'approved'
                    END
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                -- COMMUTE: Last trip of shift (work -> unknown) or first trip (unknown -> work)
                WHEN (
                    COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                    AND COALESCE(el.location_type, arr_loc.location_type) IS NULL
                    AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at)
                ) OR (
                    COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                    AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                    AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at)
                ) THEN 'rejected'
                WHEN t.duration_minutes > 30 THEN 'needs_review'
                WHEN t.distance_km > 10 THEN 'needs_review'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
                 AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
                    THEN 'needs_review'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                 AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                     / GREATEST(t.duration_minutes / 60.0, 0.01) > 130 THEN 'needs_review'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                 AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                     / GREATEST(t.duration_minutes / 60.0, 0.01) < 5 THEN 'needs_review'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            -- auto_reason
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Donnees GPS incompletes'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
                    CASE
                        WHEN t.expected_distance_km IS NOT NULL
                         AND t.distance_km > 2.0 * t.expected_distance_km
                            THEN 'Detour excessif : ' || ROUND(t.distance_km, 1) || ' km parcourus vs ' || ROUND(t.expected_distance_km, 1) || ' km attendus'
                        WHEN t.expected_duration_seconds IS NOT NULL
                         AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0)
                            THEN 'Trajet trop long : ' || t.duration_minutes || ' min vs ' || ROUND(t.expected_duration_seconds / 60.0) || ' min attendues'
                        ELSE 'Deplacement professionnel'
                    END
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN (
                    COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                    AND COALESCE(el.location_type, arr_loc.location_type) IS NULL
                    AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at)
                ) OR (
                    COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                    AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                    AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at)
                ) THEN 'Trajet domicile-travail'
                WHEN t.duration_minutes > 30 THEN 'Trajet de plus de 30 min (' || t.duration_minutes || ' min)'
                WHEN t.distance_km > 10 THEN 'Trajet de plus de 10 km (' || ROUND(t.distance_km, 1) || ' km)'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
                 AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
                    THEN 'Detour excessif (ratio ' || ROUND(t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01), 1) || 'x)'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                 AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                     / GREATEST(t.duration_minutes / 60.0, 0.01) > 130
                    THEN 'Vitesse irrealiste (' || ROUND(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) / GREATEST(t.duration_minutes / 60.0, 0.01)) || ' km/h)'
                WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                 AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                     / GREATEST(t.duration_minutes / 60.0, 0.01) < 5
                    THEN 'Trajet anormalement lent (' || ROUND(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) / GREATEST(t.duration_minutes / 60.0, 0.01)) || ' km/h)'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'Destination inconnue'
                ELSE 'A verifier'
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
          AND t.started_at >= business_day_start(p_date)
          AND t.started_at < business_day_end(p_date)

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
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (a verifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (a verifier)'
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
          AND to_business_date(s.clocked_in_at) = p_date
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
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (a verifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (a verifier)'
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
          AND to_business_date(s.clocked_out_at) = p_date
          AND s.status = 'completed'
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL

        UNION ALL

        -- LUNCH BREAKS (single row per break)
        SELECT
            'lunch'::TEXT AS activity_type,
            lb.id AS activity_id,
            lb.shift_id,
            lb.started_at,
            lb.ended_at,
            EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60 AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            0::INTEGER AS gps_gap_seconds,
            0::INTEGER AS gps_gap_count,
            'approved'::TEXT AS auto_status,
            'Pause diner'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.ended_at IS NOT NULL
          AND to_business_date(lb.started_at) = p_date
    ),
    -- Gap detection: include lunch breaks as covered periods
    real_activities AS (
        SELECT ad.shift_id, ad.started_at, ad.ended_at
        FROM activity_data ad
        WHERE ad.activity_type IN ('stop', 'trip')
        UNION ALL
        SELECT lb.shift_id, lb.started_at, lb.ended_at
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.ended_at IS NOT NULL
          AND to_business_date(lb.started_at) = p_date
    ),
    shift_boundaries AS (
        SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND to_business_date(s.clocked_in_at) = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    shift_events AS (
        SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
        FROM shift_boundaries sb
        UNION ALL
        SELECT ra.shift_id, ra.started_at, 2
        FROM real_activities ra
        UNION ALL
        SELECT ra.shift_id, ra.ended_at, 1
        FROM real_activities ra
        UNION ALL
        SELECT sb.shift_id, sb.clocked_out_at, 3
        FROM shift_boundaries sb
    ),
    ordered_events AS (
        SELECT
            shift_id, event_time, event_order,
            ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY event_time, event_order) AS rn
        FROM shift_events
    ),
    gap_pairs AS (
        SELECT
            e1.shift_id,
            e1.event_time AS gap_started_at,
            e2.event_time AS gap_ended_at,
            EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
        FROM ordered_events e1
        JOIN ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
        WHERE e1.event_order IN (0, 1)
          AND e2.event_order IN (2, 3)
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
    empty_shift_gaps AS (
        SELECT
            sb.shift_id,
            sb.clocked_in_at AS gap_started_at,
            sb.clocked_out_at AS gap_ended_at,
            EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at))::INTEGER AS gap_seconds
        FROM shift_boundaries sb
        WHERE NOT EXISTS (SELECT 1 FROM real_activities ra WHERE ra.shift_id = sb.shift_id)
          AND NOT EXISTS (SELECT 1 FROM gap_pairs gp WHERE gp.shift_id = sb.shift_id)
          AND EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at)) > 300
    ),
    all_gaps AS (
        SELECT * FROM gap_pairs
        UNION ALL
        SELECT * FROM empty_shift_gaps
    ),
    gap_activities AS (
        SELECT
            'gap'::TEXT AS activity_type,
            md5(p_employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID AS activity_id,
            g.shift_id,
            g.gap_started_at AS started_at,
            g.gap_ended_at AS ended_at,
            (g.gap_seconds / 60)::INTEGER AS duration_minutes,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::DECIMAL, NULL::DECIMAL,
            0::INTEGER, 0::INTEGER,
            'needs_review'::TEXT,
            'Temps non suivi'::TEXT,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM all_gaps g
    ),
    all_activity_data AS (
        SELECT * FROM activity_data
        UNION ALL
        SELECT * FROM gap_activities
    ),
    classified AS (
        SELECT
            ad.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, ad.auto_status) AS final_status
        FROM all_activity_data ad
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

    -- Compute summary — exclude lunch from approved_minutes (it's subtracted from total instead)
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' != 'lunch'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE
            a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out', 'lunch')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' IN ('stop', 'gap')
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
            'needs_review_count', v_needs_review_count,
            'lunch_minutes', v_lunch_minutes
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- =========================================================================
-- 2. Fix get_weekly_approval_summary — add lunch_minutes back
-- =========================================================================

CREATE OR REPLACE FUNCTION get_weekly_approval_summary(
    p_week_start DATE
)
RETURNS JSONB AS $$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
    -- Validate p_week_start is a Monday
    IF EXTRACT(ISODOW FROM p_week_start) != 1 THEN
        RAISE EXCEPTION 'p_week_start must be a Monday, got %', p_week_start;
    END IF;

    WITH employee_list AS (
        SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name
    ),
    day_shifts AS (
        SELECT
            s.employee_id,
            to_business_date(s.clocked_in_at) AS shift_date,
            SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        WHERE to_business_date(s.clocked_in_at) BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, to_business_date(s.clocked_in_at)
    ),
    -- Lunch minutes per employee per day
    day_lunch AS (
        SELECT
            lb.employee_id,
            to_business_date(lb.started_at) AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM lunch_breaks lb
        WHERE lb.ended_at IS NOT NULL
          AND to_business_date(lb.started_at) BETWEEN p_week_start AND v_week_end
          AND lb.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY lb.employee_id, to_business_date(lb.started_at)
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Live classification of stops and trips for non-approved days
    live_activity_classification AS (
        -- Stops
        SELECT
            sc.employee_id,
            to_business_date(sc.started_at) AS activity_date,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = to_business_date(sc.started_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
        WHERE to_business_date(sc.started_at) BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180

        UNION ALL

        -- Trips with anomaly detection + commute detection
        SELECT
            t.employee_id,
            to_business_date(t.started_at),
            t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
                        CASE
                            WHEN t.expected_distance_km IS NOT NULL AND t.distance_km > 2.0 * t.expected_distance_km THEN 'needs_review'
                            WHEN t.expected_duration_seconds IS NOT NULL AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0) THEN 'needs_review'
                            ELSE 'approved'
                        END
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    -- COMMUTE: Last trip of shift (work -> unknown) or first trip (unknown -> work)
                    WHEN (
                        COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                        AND COALESCE(el.location_type, arr_loc.location_type) IS NULL
                        AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at)
                    ) OR (
                        COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                        AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                        AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at)
                    ) THEN 'rejected'
                    WHEN t.duration_minutes > 30 THEN 'needs_review'
                    WHEN t.distance_km > 10 THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
                     AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
                        THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                         / GREATEST(t.duration_minutes / 60.0, 0.01) > 130 THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                         / GREATEST(t.duration_minutes / 60.0, 0.01) < 5 THEN 'needs_review'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id
            FROM stationary_clusters sc2
            WHERE sc2.employee_id = t.employee_id
              AND sc2.ended_at = t.started_at
            LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id
            FROM stationary_clusters sc3
            WHERE sc3.employee_id = t.employee_id
              AND sc3.started_at = t.ended_at
            LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = to_business_date(t.started_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE to_business_date(t.started_at) BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_day_totals AS (
        SELECT
            employee_id,
            activity_date,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'approved'), 0)::INTEGER AS live_approved,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'rejected'), 0)::INTEGER AS live_rejected,
            COALESCE(COUNT(*) FILTER (WHERE final_status = 'needs_review'), 0)::INTEGER AS live_needs_review_count
        FROM live_activity_classification
        GROUP BY employee_id, activity_date
    ),
    pending_day_stats AS (
        SELECT
            ds.employee_id,
            ds.shift_date,
            ds.total_shift_minutes,
            ds.has_active_shift,
            ea.status AS approval_status,
            ea.approved_minutes AS frozen_approved,
            ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved,
            ldt.live_rejected,
            ldt.live_needs_review_count,
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt
            ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
        LEFT JOIN day_lunch dl
            ON dl.employee_id = ds.employee_id AND dl.lunch_date = ds.shift_date
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'employee_id', el.employee_id,
            'employee_name', el.employee_name,
            'days', (
                SELECT COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'date', d::DATE,
                        'has_shifts', (pds.total_shift_minutes IS NOT NULL),
                        'has_active_shift', COALESCE(pds.has_active_shift, FALSE),
                        'status', CASE
                            WHEN pds.total_shift_minutes IS NULL THEN 'no_shift'
                            WHEN pds.has_active_shift THEN 'active'
                            WHEN pds.approval_status = 'approved' THEN 'approved'
                            WHEN COALESCE(pds.live_needs_review_count, 0) > 0 THEN 'needs_review'
                            ELSE 'pending'
                        END,
                        'total_shift_minutes', GREATEST(COALESCE(pds.total_shift_minutes, 0) - COALESCE(pds.lunch_minutes, 0), 0),
                        'approved_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_approved
                            ELSE COALESCE(pds.live_approved, 0)
                        END,
                        'rejected_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                            ELSE COALESCE(pds.live_rejected, 0)
                        END,
                        'needs_review_count', CASE
                            WHEN pds.approval_status = 'approved' THEN 0
                            ELSE COALESCE(pds.live_needs_review_count, 0)
                        END,
                        'lunch_minutes', COALESCE(pds.lunch_minutes, 0)
                    )
                    ORDER BY d::DATE
                ), '[]'::JSONB)
                FROM generate_series(p_week_start, v_week_end, INTERVAL '1 day') d
                LEFT JOIN pending_day_stats pds
                    ON pds.employee_id = el.employee_id AND pds.shift_date = d::DATE
            )
        )
        ORDER BY el.employee_name
    )
    INTO v_result
    FROM employee_list el;

    RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
