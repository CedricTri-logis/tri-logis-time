-- Migration 094: get_day_approval_detail RPC
-- Returns activity timeline for one employee's day, annotated with approval statuses

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
        -- Still build the activity list for display, but use frozen totals
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
            -- Auto classification for stops
            CASE
                WHEN l.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN sc.matched_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur'
                WHEN l.location_type = 'gaz' THEN 'Station-service'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                WHEN sc.matched_location_id IS NULL THEN 'Lieu inconnu'
                ELSE 'Lieu inconnu'
            END AS auto_reason,
            -- Extra fields for display
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

        -- TRIPS
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
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            -- Auto classification for trips
            CASE
                -- GPS gap or very long -> needs_review regardless
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                -- Both endpoints at approved locations
                WHEN sl.location_type IN ('office', 'building', 'vendor', 'gaz')
                 AND el.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                -- Either endpoint at rejected location
                WHEN sl.location_type IN ('home', 'cafe_restaurant', 'other')
                  OR el.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                -- Either endpoint unmatched
                WHEN t.start_location_id IS NULL OR t.end_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN sl.location_type IN ('office', 'building', 'vendor', 'gaz')
                 AND el.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Déplacement professionnel'
                WHEN sl.location_type IN ('home', 'cafe_restaurant', 'other')
                  OR el.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN t.start_location_id IS NULL OR t.end_location_id IS NULL THEN 'Destination inconnue'
                ELSE 'À vérifier'
            END,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            t.start_location_id,
            sl.name::TEXT AS start_location_name,
            sl.location_type::TEXT AS start_location_type,
            t.end_location_id,
            el.name::TEXT AS end_location_name,
            el.location_type::TEXT AS end_location_type
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
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
                WHEN ci_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Clock-in sur lieu de travail'
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
                WHEN co_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Clock-out sur lieu de travail'
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

    -- Compute summary from activities JSONB (already built above)
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'), 0)
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
