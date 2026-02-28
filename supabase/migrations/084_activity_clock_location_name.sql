-- Migration 084: Add location_name to get_employee_activity
-- Uses the pre-computed clock_in_location_id / clock_out_location_id FK columns
-- (added in migration 081) for direct location name resolution on clock events.

-- Must drop first because we're changing the return type (adding location_name)
DROP FUNCTION IF EXISTS get_employee_activity(UUID, DATE, DATE, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION get_employee_activity(
    p_employee_id UUID,
    p_date_from DATE,
    p_date_to DATE,
    p_type TEXT DEFAULT 'all',
    p_min_duration_seconds INTEGER DEFAULT 180
)
RETURNS TABLE (
    activity_type TEXT,
    id UUID,
    shift_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    -- Trip fields (NULL for stops/clock events)
    start_latitude DECIMAL,
    start_longitude DECIMAL,
    start_address TEXT,
    start_location_id UUID,
    start_location_name TEXT,
    end_latitude DECIMAL,
    end_longitude DECIMAL,
    end_address TEXT,
    end_location_id UUID,
    end_location_name TEXT,
    distance_km DECIMAL,
    road_distance_km DECIMAL,
    duration_minutes INTEGER,
    transport_mode TEXT,
    match_status TEXT,
    match_confidence DECIMAL,
    route_geometry TEXT,
    start_cluster_id UUID,
    end_cluster_id UUID,
    classification TEXT,
    gps_point_count INTEGER,
    -- Stop fields (NULL for trips/clock events)
    centroid_latitude DECIMAL,
    centroid_longitude DECIMAL,
    centroid_accuracy DECIMAL,
    duration_seconds INTEGER,
    cluster_gps_point_count INTEGER,
    matched_location_id UUID,
    matched_location_name TEXT,
    -- Clock event fields (NULL for trips/stops)
    clock_latitude DECIMAL,
    clock_longitude DECIMAL,
    clock_accuracy DECIMAL,
    -- Location name for clock events (from FK, NULL for trips/stops)
    location_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH trip_data AS (
        SELECT
            'trip'::TEXT AS v_type,
            t.id,
            t.shift_id,
            t.started_at,
            t.ended_at,
            t.start_latitude,
            t.start_longitude,
            t.start_address,
            t.start_location_id,
            sl.name::TEXT AS start_location_name,
            t.end_latitude,
            t.end_longitude,
            t.end_address,
            t.end_location_id,
            el.name::TEXT AS end_location_name,
            t.distance_km,
            t.road_distance_km,
            t.duration_minutes,
            t.transport_mode::TEXT,
            t.match_status::TEXT,
            t.match_confidence,
            t.route_geometry,
            t.start_cluster_id,
            t.end_cluster_id,
            t.classification::TEXT,
            t.gps_point_count,
            NULL::DECIMAL AS centroid_latitude,
            NULL::DECIMAL AS centroid_longitude,
            NULL::DECIMAL AS centroid_accuracy,
            NULL::INTEGER AS duration_seconds,
            NULL::INTEGER AS cluster_gps_point_count,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS matched_location_name,
            NULL::DECIMAL AS clock_latitude,
            NULL::DECIMAL AS clock_longitude,
            NULL::DECIMAL AS clock_accuracy,
            NULL::TEXT AS location_name
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date_from::TIMESTAMPTZ
          AND t.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND (p_type = 'all' OR p_type = 'trips')
    ),
    stop_data AS (
        SELECT
            'stop'::TEXT AS v_type,
            sc.id,
            sc.shift_id,
            sc.started_at,
            sc.ended_at,
            NULL::DECIMAL AS start_latitude,
            NULL::DECIMAL AS start_longitude,
            NULL::TEXT AS start_address,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::DECIMAL AS end_latitude,
            NULL::DECIMAL AS end_longitude,
            NULL::TEXT AS end_address,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::INTEGER AS duration_minutes,
            NULL::TEXT AS transport_mode,
            NULL::TEXT AS match_status,
            NULL::DECIMAL AS match_confidence,
            NULL::TEXT AS route_geometry,
            NULL::UUID AS start_cluster_id,
            NULL::UUID AS end_cluster_id,
            NULL::TEXT AS classification,
            NULL::INTEGER AS gps_point_count,
            sc.centroid_latitude,
            sc.centroid_longitude,
            sc.centroid_accuracy,
            sc.duration_seconds,
            sc.gps_point_count AS cluster_gps_point_count,
            sc.matched_location_id,
            l.name::TEXT AS matched_location_name,
            NULL::DECIMAL AS clock_latitude,
            NULL::DECIMAL AS clock_longitude,
            NULL::DECIMAL AS clock_accuracy,
            NULL::TEXT AS location_name
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date_from::TIMESTAMPTZ
          AND sc.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= p_min_duration_seconds
          AND (p_type = 'all' OR p_type = 'stops')
    ),
    clock_in_data AS (
        SELECT
            'clock_in'::TEXT AS v_type,
            s.id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_in_at AS ended_at,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::TEXT,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::TEXT,
            NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::TEXT, NULL::TEXT,
            NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::UUID, NULL::TEXT, NULL::INTEGER,
            NULL::DECIMAL, NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::INTEGER,
            ci_loc.id AS matched_location_id,
            ci_loc.name::TEXT AS matched_location_name,
            (s.clock_in_location->>'latitude')::DECIMAL AS clock_latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS clock_longitude,
            s.clock_in_accuracy AS clock_accuracy,
            l_in.name::TEXT AS location_name
        FROM shifts s
        LEFT JOIN locations l_in ON l_in.id = s.clock_in_location_id
        LEFT JOIN LATERAL (
            SELECT l.id, l.name
            FROM locations l
            WHERE l.is_active = TRUE
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
          AND s.clocked_in_at >= p_date_from::TIMESTAMPTZ
          AND s.clocked_in_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND s.clock_in_location IS NOT NULL
    ),
    clock_out_data AS (
        SELECT
            'clock_out'::TEXT AS v_type,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at AS started_at,
            s.clocked_out_at AS ended_at,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::TEXT,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::TEXT,
            NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::TEXT, NULL::TEXT,
            NULL::DECIMAL, NULL::TEXT, NULL::UUID, NULL::UUID, NULL::TEXT, NULL::INTEGER,
            NULL::DECIMAL, NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::INTEGER,
            co_loc.id AS matched_location_id,
            co_loc.name::TEXT AS matched_location_name,
            (s.clock_out_location->>'latitude')::DECIMAL AS clock_latitude,
            (s.clock_out_location->>'longitude')::DECIMAL AS clock_longitude,
            s.clock_out_accuracy AS clock_accuracy,
            l_out.name::TEXT AS location_name
        FROM shifts s
        LEFT JOIN locations l_out ON l_out.id = s.clock_out_location_id
        LEFT JOIN LATERAL (
            SELECT l.id, l.name
            FROM locations l
            WHERE l.is_active = TRUE
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
          AND s.clocked_out_at >= p_date_from::TIMESTAMPTZ
          AND s.clocked_out_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
    )
    SELECT
        td.v_type,
        td.id, td.shift_id, td.started_at, td.ended_at,
        td.start_latitude, td.start_longitude, td.start_address,
        td.start_location_id, td.start_location_name,
        td.end_latitude, td.end_longitude, td.end_address,
        td.end_location_id, td.end_location_name,
        td.distance_km, td.road_distance_km, td.duration_minutes,
        td.transport_mode, td.match_status, td.match_confidence,
        td.route_geometry, td.start_cluster_id, td.end_cluster_id,
        td.classification, td.gps_point_count,
        td.centroid_latitude, td.centroid_longitude, td.centroid_accuracy,
        td.duration_seconds, td.cluster_gps_point_count,
        td.matched_location_id, td.matched_location_name,
        td.clock_latitude, td.clock_longitude, td.clock_accuracy,
        td.location_name
    FROM (
        SELECT * FROM trip_data
        UNION ALL
        SELECT * FROM stop_data
        UNION ALL
        SELECT * FROM clock_in_data
        UNION ALL
        SELECT * FROM clock_out_data
    ) td
    ORDER BY td.started_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
