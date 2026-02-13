-- GPS Clock-In Tracker: Location Geofences & Shift Segmentation
-- Migration: 015_location_geofences
-- Date: 2026-01-17
-- Feature: Workplace location management with geofences and shift timeline segmentation

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

-- Enable PostGIS for spatial queries (geography type, ST_Distance, ST_DWithin)
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- =============================================================================
-- ENUMS
-- =============================================================================

-- Location type classification for workplace geofences
CREATE TYPE location_type AS ENUM (
    'office',    -- Corporate office, administrative building
    'building',  -- Construction site, job site
    'vendor',    -- Supplier, external partner location
    'home',      -- Employee home (work from home)
    'other'      -- Miscellaneous locations
);

COMMENT ON TYPE location_type IS 'Classification types for workplace locations';

-- =============================================================================
-- TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- locations: Workplace geofences with circular boundaries
-- -----------------------------------------------------------------------------
CREATE TABLE locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    location_type location_type NOT NULL,
    -- PostGIS geography point for accurate distance calculations
    location geography(POINT, 4326) NOT NULL,
    radius_meters NUMERIC(10,2) NOT NULL DEFAULT 100
        CHECK (radius_meters >= 10 AND radius_meters <= 1000),
    -- Computed columns for API convenience (avoid needing ST_X/ST_Y in client)
    latitude DOUBLE PRECISION GENERATED ALWAYS AS (ST_Y(location::geometry)) STORED,
    longitude DOUBLE PRECISION GENERATED ALWAYS AS (ST_X(location::geometry)) STORED,
    address TEXT,
    notes TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE locations IS 'Workplace geofences with circular boundaries for GPS matching';
COMMENT ON COLUMN locations.location IS 'PostGIS geography point (center of geofence)';
COMMENT ON COLUMN locations.radius_meters IS 'Geofence radius in meters (10-1000)';
COMMENT ON COLUMN locations.latitude IS 'Computed latitude for API convenience';
COMMENT ON COLUMN locations.longitude IS 'Computed longitude for API convenience';

-- Indexes
CREATE INDEX idx_locations_geo ON locations USING GIST (location);
CREATE INDEX idx_locations_active ON locations(is_active);
CREATE INDEX idx_locations_type ON locations(location_type);
CREATE INDEX idx_locations_name ON locations(name);

-- -----------------------------------------------------------------------------
-- location_matches: GPS point to location associations (cached matches)
-- -----------------------------------------------------------------------------
CREATE TABLE location_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gps_point_id UUID NOT NULL REFERENCES gps_points(id) ON DELETE CASCADE,
    location_id UUID NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
    distance_meters DOUBLE PRECISION NOT NULL,
    confidence_score DOUBLE PRECISION NOT NULL
        CHECK (confidence_score >= 0 AND confidence_score <= 1),
    matched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT location_matches_unique UNIQUE (gps_point_id, location_id)
);

COMMENT ON TABLE location_matches IS 'Cached GPS-to-location matches for timeline computation';
COMMENT ON COLUMN location_matches.distance_meters IS 'Distance from GPS point to location center';
COMMENT ON COLUMN location_matches.confidence_score IS 'Confidence: 1.0 at center, 0.0 at edge';

-- Indexes
CREATE INDEX idx_location_matches_gps ON location_matches(gps_point_id);
CREATE INDEX idx_location_matches_location ON location_matches(location_id);

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Trigger to update updated_at on locations table
CREATE OR REPLACE FUNCTION update_locations_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER locations_updated_at_trigger
    BEFORE UPDATE ON locations
    FOR EACH ROW
    EXECUTE FUNCTION update_locations_updated_at();

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

-- Enable RLS on both tables
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_matches ENABLE ROW LEVEL SECURITY;

-- Helper function to check if user has supervisor or higher role
CREATE OR REPLACE FUNCTION public.has_supervisor_role()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM employee_profiles
        WHERE id = auth.uid()
        AND role IN ('super_admin', 'admin', 'manager', 'supervisor')
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- Locations: All supervisors can read all locations (company-wide resource)
CREATE POLICY locations_select_policy ON locations
    FOR SELECT
    TO authenticated
    USING (public.has_supervisor_role());

-- Locations: Supervisors can create locations
CREATE POLICY locations_insert_policy ON locations
    FOR INSERT
    TO authenticated
    WITH CHECK (public.has_supervisor_role());

-- Locations: Supervisors can update locations
CREATE POLICY locations_update_policy ON locations
    FOR UPDATE
    TO authenticated
    USING (public.has_supervisor_role())
    WITH CHECK (public.has_supervisor_role());

-- Locations: Only admins can delete locations
CREATE POLICY locations_delete_policy ON locations
    FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE id = auth.uid()
            AND role IN ('super_admin', 'admin')
        )
    );

-- Location matches: Can read if user can access the associated shift
CREATE POLICY location_matches_select_policy ON location_matches
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM gps_points gp
            JOIN shifts s ON s.id = gp.shift_id
            JOIN employee_supervisors es ON es.employee_id = s.employee_id
            WHERE gp.id = location_matches.gps_point_id
            AND es.manager_id = auth.uid()
        )
        OR
        EXISTS (
            SELECT 1 FROM gps_points gp
            JOIN shifts s ON s.id = gp.shift_id
            WHERE gp.id = location_matches.gps_point_id
            AND s.employee_id = auth.uid()
        )
        OR
        EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE id = auth.uid()
            AND role IN ('super_admin', 'admin', 'manager')
        )
    );

-- Location matches: Only system (via RPC) can insert - no direct inserts
CREATE POLICY location_matches_insert_policy ON location_matches
    FOR INSERT
    TO authenticated
    WITH CHECK (public.has_supervisor_role());

-- =============================================================================
-- RPC FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- get_locations_paginated: Retrieve locations with pagination and filtering
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_locations_paginated(
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0,
    p_search TEXT DEFAULT NULL,
    p_location_type location_type DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_sort_by TEXT DEFAULT 'name',
    p_sort_order TEXT DEFAULT 'asc'
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    location_type location_type,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    radius_meters NUMERIC(10,2),
    address TEXT,
    notes TEXT,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    total_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_total_count BIGINT;
    v_sort_column TEXT;
    v_sort_direction TEXT;
BEGIN
    -- Validate sort column
    v_sort_column := CASE p_sort_by
        WHEN 'name' THEN 'name'
        WHEN 'created_at' THEN 'created_at'
        WHEN 'updated_at' THEN 'updated_at'
        WHEN 'location_type' THEN 'location_type'
        ELSE 'name'
    END;

    -- Validate sort direction
    v_sort_direction := CASE WHEN LOWER(p_sort_order) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- Get total count for pagination
    SELECT COUNT(*) INTO v_total_count
    FROM locations l
    WHERE (p_search IS NULL OR l.name ILIKE '%' || p_search || '%' OR l.address ILIKE '%' || p_search || '%')
      AND (p_location_type IS NULL OR l.location_type = p_location_type)
      AND (p_is_active IS NULL OR l.is_active = p_is_active);

    -- Return results with total count
    RETURN QUERY EXECUTE format(
        'SELECT
            l.id,
            l.name,
            l.location_type,
            l.latitude,
            l.longitude,
            l.radius_meters,
            l.address,
            l.notes,
            l.is_active,
            l.created_at,
            l.updated_at,
            $1::bigint as total_count
        FROM locations l
        WHERE ($2 IS NULL OR l.name ILIKE ''%%'' || $2 || ''%%'' OR l.address ILIKE ''%%'' || $2 || ''%%'')
          AND ($3 IS NULL OR l.location_type = $3)
          AND ($4 IS NULL OR l.is_active = $4)
        ORDER BY %I %s
        LIMIT $5 OFFSET $6',
        v_sort_column,
        v_sort_direction
    )
    USING v_total_count, p_search, p_location_type, p_is_active, LEAST(p_limit, 100), p_offset;
END;
$$;

COMMENT ON FUNCTION get_locations_paginated IS 'Retrieve locations with pagination, filtering, and search';

-- -----------------------------------------------------------------------------
-- match_shift_gps_to_locations: Match GPS points to closest containing location
-- -----------------------------------------------------------------------------
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
BEGIN
    -- First, insert new matches for GPS points that don't have matches yet
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

-- -----------------------------------------------------------------------------
-- get_shift_timeline: Get timeline segments for a shift
-- -----------------------------------------------------------------------------
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
BEGIN
    -- First ensure matches are computed
    PERFORM match_shift_gps_to_locations(p_shift_id);

    -- Return timeline segments grouped by consecutive location
    RETURN QUERY
    WITH matched_points AS (
        SELECT
            gp.id AS gps_point_id,
            gp.captured_at,
            lm.location_id,
            l.name AS location_name,
            l.location_type,
            lm.confidence_score,
            -- Assign group number based on location changes
            SUM(CASE WHEN lm.location_id IS DISTINCT FROM LAG(lm.location_id) OVER (ORDER BY gp.captured_at)
                     THEN 1 ELSE 0 END) OVER (ORDER BY gp.captured_at) AS segment_group
        FROM gps_points gp
        LEFT JOIN location_matches lm ON lm.gps_point_id = gp.id
        LEFT JOIN locations l ON l.id = lm.location_id
        WHERE gp.shift_id = p_shift_id
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
            -- Classify null-location segments
            CASE
                WHEN s.location_id IS NOT NULL THEN 'matched'
                -- Check if this null segment is between two DIFFERENT matched locations
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

-- -----------------------------------------------------------------------------
-- bulk_insert_locations: Insert multiple locations in a single transaction
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bulk_insert_locations(
    p_locations JSONB
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    success BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_location JSONB;
    v_id UUID;
    v_name TEXT;
    v_error TEXT;
BEGIN
    -- Process each location in the array
    FOR v_location IN SELECT * FROM jsonb_array_elements(p_locations)
    LOOP
        v_name := v_location->>'name';
        v_id := NULL;
        v_error := NULL;

        BEGIN
            INSERT INTO locations (
                name,
                location_type,
                location,
                radius_meters,
                address,
                notes,
                is_active
            ) VALUES (
                v_location->>'name',
                (v_location->>'location_type')::location_type,
                ST_SetSRID(
                    ST_MakePoint(
                        (v_location->>'longitude')::float,
                        (v_location->>'latitude')::float
                    ),
                    4326
                )::geography,
                COALESCE((v_location->>'radius_meters')::numeric, 100),
                v_location->>'address',
                v_location->>'notes',
                COALESCE((v_location->>'is_active')::boolean, true)
            )
            RETURNING locations.id INTO v_id;

            id := v_id;
            name := v_name;
            success := TRUE;
            error_message := NULL;
            RETURN NEXT;

        EXCEPTION WHEN OTHERS THEN
            id := NULL;
            name := v_name;
            success := FALSE;
            error_message := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION bulk_insert_locations IS 'Bulk insert locations from JSON array (for CSV import)';

-- -----------------------------------------------------------------------------
-- check_shift_matches_exist: Check if a shift has cached location matches
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_shift_matches_exist(
    p_shift_id UUID
)
RETURNS TABLE (
    has_matches BOOLEAN,
    match_count BIGINT,
    matched_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT
        COUNT(*) > 0 AS has_matches,
        COUNT(*) AS match_count,
        MAX(lm.matched_at) AS matched_at
    FROM gps_points gp
    JOIN location_matches lm ON lm.gps_point_id = gp.id
    WHERE gp.shift_id = p_shift_id;
$$;

COMMENT ON FUNCTION check_shift_matches_exist IS 'Check if a shift has cached location matches';

-- =============================================================================
-- GRANTS
-- =============================================================================

-- Grant execute on all RPC functions to authenticated users
GRANT EXECUTE ON FUNCTION get_locations_paginated TO authenticated;
GRANT EXECUTE ON FUNCTION match_shift_gps_to_locations TO authenticated;
GRANT EXECUTE ON FUNCTION get_shift_timeline TO authenticated;
GRANT EXECUTE ON FUNCTION bulk_insert_locations TO authenticated;
GRANT EXECUTE ON FUNCTION check_shift_matches_exist TO authenticated;
GRANT EXECUTE ON FUNCTION has_supervisor_role TO authenticated;
