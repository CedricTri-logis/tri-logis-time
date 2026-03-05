-- ============================================================
-- 133: Location overlap prevention
-- ============================================================

-- Drop old overload of get_nearby_locations (3 params, no p_exclude_id, no lat/lng)
DROP FUNCTION IF EXISTS get_nearby_locations(numeric, numeric, integer);

-- 1. Replace get_nearby_locations to also return lat/lng
--    (used by the edit map to render neighbor circles)
CREATE OR REPLACE FUNCTION get_nearby_locations(
    p_latitude NUMERIC,
    p_longitude NUMERIC,
    p_limit INTEGER DEFAULT 20,
    p_exclude_id UUID DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    name TEXT,
    location_type TEXT,
    distance_meters DOUBLE PRECISION,
    radius_meters NUMERIC,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT
        l.id,
        l.name,
        l.location_type::TEXT,
        ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
        ) AS distance_meters,
        l.radius_meters,
        l.latitude,
        l.longitude
    FROM locations l
    WHERE l.is_active = TRUE
      AND (p_exclude_id IS NULL OR l.id != p_exclude_id)
    ORDER BY distance_meters ASC
    LIMIT p_limit;
END;
$$;

-- 2. check_location_overlap: returns overlapping active locations
--    Overlap = distance between centers < sum of radii
CREATE OR REPLACE FUNCTION check_location_overlap(
    p_latitude NUMERIC,
    p_longitude NUMERIC,
    p_radius_meters NUMERIC,
    p_exclude_id UUID DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    name TEXT,
    location_type TEXT,
    distance_meters DOUBLE PRECISION,
    radius_meters NUMERIC,
    overlap_meters DOUBLE PRECISION
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT
        l.id,
        l.name,
        l.location_type::TEXT,
        ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
        ) AS distance_meters,
        l.radius_meters,
        (l.radius_meters + p_radius_meters) - ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
        ) AS overlap_meters
    FROM locations l
    WHERE l.is_active = TRUE
      AND (p_exclude_id IS NULL OR l.id != p_exclude_id)
      AND ST_DWithin(
          l.location,
          ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography,
          l.radius_meters + p_radius_meters
      )
    ORDER BY distance_meters ASC;
END;
$$;

-- 3. Update bulk_insert_locations to check overlap before each insert
CREATE OR REPLACE FUNCTION bulk_insert_locations(p_locations JSONB)
RETURNS TABLE(id UUID, name TEXT, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_location JSONB;
    v_id UUID;
    v_name TEXT;
    v_lat NUMERIC;
    v_lng NUMERIC;
    v_radius NUMERIC;
    v_overlap_name TEXT;
    v_overlap_distance NUMERIC;
BEGIN
    FOR v_location IN SELECT * FROM jsonb_array_elements(p_locations) LOOP
        v_name := v_location->>'name';
        v_id := NULL;

        v_lat := (v_location->>'latitude')::NUMERIC;
        v_lng := (v_location->>'longitude')::NUMERIC;
        v_radius := COALESCE((v_location->>'radius_meters')::NUMERIC, 100);

        -- Check for overlap with existing locations
        SELECT ol.name, ol.distance_meters
        INTO v_overlap_name, v_overlap_distance
        FROM check_location_overlap(v_lat, v_lng, v_radius) ol
        LIMIT 1;

        IF v_overlap_name IS NOT NULL THEN
            id := NULL;
            name := v_name;
            success := FALSE;
            error_message := format(
                'Chevauchement avec "%s" (distance: %sm, chevauchement: %sm)',
                v_overlap_name,
                round(v_overlap_distance::NUMERIC, 1),
                round((v_radius + (SELECT l.radius_meters FROM locations l WHERE l.name = v_overlap_name LIMIT 1) - v_overlap_distance)::NUMERIC, 1)
            );
            RETURN NEXT;
            CONTINUE;
        END IF;

        BEGIN
            INSERT INTO locations (name, location_type, location, radius_meters, address, notes, is_active)
            VALUES (
                v_name,
                (v_location->>'location_type')::location_type,
                ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
                v_radius,
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
