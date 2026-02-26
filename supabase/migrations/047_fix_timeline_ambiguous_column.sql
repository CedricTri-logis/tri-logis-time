-- =============================================================================
-- Migration 047: Fix ambiguous column reference in match_shift_gps_to_locations
-- =============================================================================
-- The RETURNS TABLE column `gps_point_id` clashes with
-- `location_matches.gps_point_id` inside PL/pgSQL, causing:
--   "column reference gps_point_id is ambiguous"
-- Fix: add #variable_conflict use_column to prefer table columns.
-- =============================================================================

-- Drop and recreate to ensure clean state
DROP FUNCTION IF EXISTS match_shift_gps_to_locations(UUID);

CREATE OR REPLACE FUNCTION match_shift_gps_to_locations(
    p_shift_id UUID
)
RETURNS TABLE (
    gps_point_id UUID,
    gps_latitude DOUBLE PRECISION,
    gps_longitude DOUBLE PRECISION,
    captured_at TIMESTAMPTZ,
    location_id UUID,
    location_name TEXT,
    location_type location_type,
    distance_meters DOUBLE PRECISION,
    confidence_score DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
#variable_conflict use_column
BEGIN
    -- Insert new matches for GPS points that don't have matches yet
    INSERT INTO location_matches (gps_point_id, location_id, distance_meters, confidence_score)
    SELECT
        gp.id AS gps_point_id,
        closest.location_id,
        closest.distance_meters,
        GREATEST(0, 1 - (closest.distance_meters / closest.radius_meters)) AS confidence_score
    FROM gps_points gp
    CROSS JOIN LATERAL (
        SELECT
            l.id AS location_id,
            l.radius_meters,
            ST_Distance(
                l.location,
                ST_SetSRID(ST_MakePoint(gp.longitude::float, gp.latitude::float), 4326)::geography
            ) AS distance_meters
        FROM locations l
        WHERE l.is_active = TRUE
          AND ST_DWithin(
              l.location,
              ST_SetSRID(ST_MakePoint(gp.longitude::float, gp.latitude::float), 4326)::geography,
              l.radius_meters
          )
        ORDER BY ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(gp.longitude::float, gp.latitude::float), 4326)::geography
        )
        LIMIT 1
    ) AS closest
    WHERE gp.shift_id = p_shift_id
      AND NOT EXISTS (
          SELECT 1 FROM location_matches lm WHERE lm.gps_point_id = gp.id
      )
    ON CONFLICT (gps_point_id, location_id) DO NOTHING;

    -- Return all GPS points with their matches (or NULL if unmatched)
    RETURN QUERY
    SELECT
        gp.id AS gps_point_id,
        gp.latitude::double precision AS gps_latitude,
        gp.longitude::double precision AS gps_longitude,
        gp.captured_at,
        lm.location_id,
        l.name AS location_name,
        l.location_type,
        lm.distance_meters,
        lm.confidence_score
    FROM gps_points gp
    LEFT JOIN location_matches lm ON lm.gps_point_id = gp.id
    LEFT JOIN locations l ON l.id = lm.location_id
    WHERE gp.shift_id = p_shift_id
    ORDER BY gp.captured_at ASC;
END;
$$;

COMMENT ON FUNCTION match_shift_gps_to_locations IS 'Match all GPS points of a shift to their closest containing geofence';

-- =============================================================================
-- Also fix get_shift_timeline: nested window functions (LAG inside SUM OVER)
-- Split into two CTEs to avoid "window function calls cannot be nested"
-- =============================================================================

CREATE OR REPLACE FUNCTION get_shift_timeline(
    p_shift_id UUID
)
RETURNS TABLE (
    segment_index INTEGER,
    segment_type TEXT,
    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,
    duration_seconds INTEGER,
    point_count INTEGER,
    location_id UUID,
    location_name TEXT,
    location_type location_type,
    avg_confidence DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
#variable_conflict use_column
BEGIN
    -- First ensure matches are computed
    PERFORM match_shift_gps_to_locations(p_shift_id);

    -- Return timeline segments grouped by consecutive location
    RETURN QUERY
    WITH point_locations AS (
        -- Step 1: get each point's location + previous location via LAG
        SELECT
            gp.id AS gps_point_id,
            gp.captured_at,
            lm.location_id,
            l.name AS location_name,
            l.location_type,
            lm.confidence_score,
            LAG(lm.location_id) OVER (ORDER BY gp.captured_at) AS prev_location_id
        FROM gps_points gp
        LEFT JOIN location_matches lm ON lm.gps_point_id = gp.id
        LEFT JOIN locations l ON l.id = lm.location_id
        WHERE gp.shift_id = p_shift_id
    ),
    matched_points AS (
        -- Step 2: compute segment groups from location changes (no nested window functions)
        SELECT
            pl.*,
            SUM(CASE WHEN pl.location_id IS DISTINCT FROM pl.prev_location_id
                     THEN 1 ELSE 0 END) OVER (ORDER BY pl.captured_at) AS segment_group
        FROM point_locations pl
    ),
    segments AS (
        SELECT
            segment_group,
            MIN(captured_at) AS start_time,
            MAX(captured_at) AS end_time,
            COUNT(*)::integer AS point_count,
            mp.location_id,
            mp.location_name,
            mp.location_type,
            AVG(mp.confidence_score) AS avg_confidence
        FROM matched_points mp
        GROUP BY segment_group, mp.location_id, mp.location_name, mp.location_type
    ),
    classified AS (
        SELECT
            s.*,
            CASE
                WHEN s.location_id IS NOT NULL THEN 'matched'
                WHEN (
                    SELECT location_id FROM segments
                    WHERE segment_group < s.segment_group AND location_id IS NOT NULL
                    ORDER BY segment_group DESC LIMIT 1
                ) IS DISTINCT FROM (
                    SELECT location_id FROM segments
                    WHERE segment_group > s.segment_group AND location_id IS NOT NULL
                    ORDER BY segment_group ASC LIMIT 1
                )
                AND (
                    SELECT location_id FROM segments
                    WHERE segment_group < s.segment_group AND location_id IS NOT NULL
                    ORDER BY segment_group DESC LIMIT 1
                ) IS NOT NULL
                AND (
                    SELECT location_id FROM segments
                    WHERE segment_group > s.segment_group AND location_id IS NOT NULL
                    ORDER BY segment_group ASC LIMIT 1
                ) IS NOT NULL
                THEN 'travel'
                ELSE 'unmatched'
            END AS segment_type
        FROM segments s
    )
    SELECT
        (ROW_NUMBER() OVER (ORDER BY c.start_time))::integer AS segment_index,
        c.segment_type,
        c.start_time,
        c.end_time,
        EXTRACT(EPOCH FROM (c.end_time - c.start_time))::integer AS duration_seconds,
        c.point_count,
        c.location_id,
        c.location_name,
        c.location_type,
        c.avg_confidence
    FROM classified c
    ORDER BY c.start_time;
END;
$$;

COMMENT ON FUNCTION get_shift_timeline IS 'Get timeline segments for a shift with matched/travel/unmatched classification';
