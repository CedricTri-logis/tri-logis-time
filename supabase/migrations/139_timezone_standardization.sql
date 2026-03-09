-- =============================================================================
-- 139: Timezone standardization
-- =============================================================================
-- Creates app_settings table with configurable business timezone and 3 helper
-- functions. Rewrites all SQL functions to use helpers instead of hardcoded
-- timezone or bare UTC ::DATE casts.
-- =============================================================================

-- =========================================================================
-- Section A: Infrastructure
-- =========================================================================

-- 1. Config table (single-row)
CREATE TABLE IF NOT EXISTS app_settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    timezone TEXT NOT NULL DEFAULT 'America/Toronto'
);
INSERT INTO app_settings (id, timezone) VALUES (1, 'America/Toronto')
ON CONFLICT (id) DO NOTHING;

-- 2. Helper: TIMESTAMPTZ -> business DATE
CREATE OR REPLACE FUNCTION to_business_date(ts TIMESTAMPTZ)
RETURNS DATE AS $$
    SELECT (ts AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1))::DATE;
$$ LANGUAGE sql STABLE;

-- 3. Helper: DATE -> start of business day as TIMESTAMPTZ
CREATE OR REPLACE FUNCTION business_day_start(d DATE)
RETURNS TIMESTAMPTZ AS $$
    SELECT (d::TEXT || ' 00:00:00')::TIMESTAMP
           AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1);
$$ LANGUAGE sql STABLE;

-- 4. Helper: DATE -> end of business day (= start of next day) as TIMESTAMPTZ
CREATE OR REPLACE FUNCTION business_day_end(d DATE)
RETURNS TIMESTAMPTZ AS $$
    SELECT ((d + 1)::TEXT || ' 00:00:00')::TIMESTAMP
           AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1);
$$ LANGUAGE sql STABLE;

-- =========================================================================
-- Section B: Fix get_weekly_approval_summary (base: migration 127)
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
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Live classification of stops and trips for non-approved days
    live_activity_classification AS (
        -- Stops (same rules as get_day_approval_detail migration 122)
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

        -- Trips with cluster-based location fallback (same as migration 122)
        SELECT
            t.employee_id,
            to_business_date(t.started_at),
            t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                    WHEN t.duration_minutes > 60 THEN 'needs_review'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'approved'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
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
            ldt.live_needs_review_count
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt
            ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
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
                        'total_shift_minutes', COALESCE(pds.total_shift_minutes, 0),
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
                        END
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

-- =========================================================================
-- Section C: Fix get_day_approval_detail (base: migration 122)
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
          AND sc.started_at >= business_day_start(p_date)
          AND sc.started_at < business_day_end(p_date)
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
          AND to_business_date(s.clocked_out_at) = p_date
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
-- Section D: Fix detect_carpools (base: migration 077)
-- =========================================================================

CREATE OR REPLACE FUNCTION detect_carpools(p_date DATE)
RETURNS TABLE (
    carpool_group_id UUID,
    member_count INTEGER,
    driver_employee_id UUID,
    review_needed BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_trip RECORD;
    v_other RECORD;
    v_overlap_seconds DOUBLE PRECISION;
    v_shorter_duration DOUBLE PRECISION;
    v_start_dist DOUBLE PRECISION;
    v_end_dist DOUBLE PRECISION;
    v_group_id UUID;
    v_existing_group UUID;
    v_other_group UUID;
    v_personal_count INTEGER;
    v_driver_id UUID;
    v_needs_review BOOLEAN;
    v_member RECORD;
BEGIN
    -- Step 0: Delete existing carpool data for this date (idempotent)
    DELETE FROM carpool_members cm_del
    WHERE cm_del.carpool_group_id IN (
        SELECT id FROM carpool_groups WHERE trip_date = p_date
    );
    DELETE FROM carpool_groups WHERE trip_date = p_date;

    -- Step 1: Create temp table for trip pairs
    CREATE TEMP TABLE IF NOT EXISTS temp_trip_pairs (
        trip_a UUID,
        trip_b UUID,
        employee_a UUID,
        employee_b UUID
    ) ON COMMIT DROP;
    TRUNCATE temp_trip_pairs;

    -- Step 2: Find all driving trips on this date
    CREATE TEMP TABLE IF NOT EXISTS temp_day_trips AS
    SELECT id, employee_id, started_at, ended_at,
           start_latitude, start_longitude,
           end_latitude, end_longitude,
           EXTRACT(EPOCH FROM (ended_at - started_at)) AS duration_seconds
    FROM trips
    WHERE to_business_date(started_at) = p_date
      AND transport_mode = 'driving'
      AND EXTRACT(EPOCH FROM (ended_at - started_at)) > 0
    ORDER BY started_at;

    -- Step 3: Compare all pairs (O(n^2) but n is small per day)
    FOR v_trip IN SELECT * FROM temp_day_trips LOOP
        FOR v_other IN
            SELECT * FROM temp_day_trips
            WHERE id > v_trip.id  -- avoid duplicate pairs
              AND employee_id != v_trip.employee_id
        LOOP
            -- Calculate haversine distances for start and end points
            v_start_dist := haversine_km(
                v_trip.start_latitude, v_trip.start_longitude,
                v_other.start_latitude, v_other.start_longitude
            );
            v_end_dist := haversine_km(
                v_trip.end_latitude, v_trip.end_longitude,
                v_other.end_latitude, v_other.end_longitude
            );

            -- Check proximity: both start and end within 200m (0.2 km)
            IF v_start_dist < 0.2 AND v_end_dist < 0.2 THEN
                -- Check temporal overlap > 80%
                v_overlap_seconds := GREATEST(0,
                    EXTRACT(EPOCH FROM (
                        LEAST(v_trip.ended_at, v_other.ended_at) -
                        GREATEST(v_trip.started_at, v_other.started_at)
                    ))
                );
                v_shorter_duration := LEAST(v_trip.duration_seconds, v_other.duration_seconds);

                IF v_shorter_duration > 0 AND (v_overlap_seconds / v_shorter_duration) >= 0.8 THEN
                    INSERT INTO temp_trip_pairs (trip_a, trip_b, employee_a, employee_b)
                    VALUES (v_trip.id, v_other.id, v_trip.employee_id, v_other.employee_id);
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    -- Step 4: Group pairs transitively using union-find via temp table
    CREATE TEMP TABLE IF NOT EXISTS temp_trip_groups (
        trip_id UUID PRIMARY KEY,
        group_id UUID
    ) ON COMMIT DROP;
    TRUNCATE temp_trip_groups;

    FOR v_trip IN SELECT * FROM temp_trip_pairs LOOP
        -- Check if either trip already has a group
        SELECT group_id INTO v_existing_group FROM temp_trip_groups WHERE trip_id = v_trip.trip_a;
        SELECT group_id INTO v_other_group FROM temp_trip_groups WHERE trip_id = v_trip.trip_b;

        IF v_existing_group IS NOT NULL AND v_other_group IS NOT NULL THEN
            -- Both have groups: merge (update all of other_group to existing_group)
            IF v_existing_group != v_other_group THEN
                UPDATE temp_trip_groups SET group_id = v_existing_group
                WHERE group_id = v_other_group;
            END IF;
        ELSIF v_existing_group IS NOT NULL THEN
            -- Only A has a group: add B to it
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_b, v_existing_group)
            ON CONFLICT (trip_id) DO NOTHING;
        ELSIF v_other_group IS NOT NULL THEN
            -- Only B has a group: add A to it
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_a, v_other_group)
            ON CONFLICT (trip_id) DO NOTHING;
        ELSE
            -- Neither has a group: create new group
            v_group_id := gen_random_uuid();
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_a, v_group_id);
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_b, v_group_id)
            ON CONFLICT (trip_id) DO NOTHING;
        END IF;
    END LOOP;

    -- Step 5: Create carpool_groups and members for each group
    FOR v_trip IN
        SELECT DISTINCT group_id FROM temp_trip_groups
    LOOP
        -- Count members with active personal vehicle period
        SELECT COUNT(*) INTO v_personal_count
        FROM temp_trip_groups tg
        JOIN trips t ON t.id = tg.trip_id
        WHERE tg.group_id = v_trip.group_id
          AND has_active_vehicle_period(t.employee_id, 'personal', p_date);

        -- Determine driver and review status
        IF v_personal_count = 1 THEN
            SELECT t.employee_id INTO v_driver_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            WHERE tg.group_id = v_trip.group_id
              AND has_active_vehicle_period(t.employee_id, 'personal', p_date)
            LIMIT 1;
            v_needs_review := false;
        ELSIF v_personal_count = 0 THEN
            v_driver_id := NULL;
            v_needs_review := true;
        ELSE
            SELECT t.employee_id INTO v_driver_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            JOIN employee_profiles ep ON ep.id = t.employee_id
            WHERE tg.group_id = v_trip.group_id
              AND has_active_vehicle_period(t.employee_id, 'personal', p_date)
            ORDER BY ep.name ASC
            LIMIT 1;
            v_needs_review := true;
        END IF;

        -- Create carpool group
        v_group_id := gen_random_uuid();
        INSERT INTO carpool_groups (id, trip_date, driver_employee_id, review_needed)
        VALUES (v_group_id, p_date, v_driver_id, v_needs_review);

        -- Create members with roles
        FOR v_member IN
            SELECT tg.trip_id, t.employee_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            WHERE tg.group_id = v_trip.group_id
        LOOP
            INSERT INTO carpool_members (carpool_group_id, trip_id, employee_id, role)
            VALUES (
                v_group_id,
                v_member.trip_id,
                v_member.employee_id,
                CASE
                    WHEN v_driver_id IS NULL THEN 'unassigned'
                    WHEN v_member.employee_id = v_driver_id THEN 'driver'
                    ELSE 'passenger'
                END
            );
        END LOOP;
    END LOOP;

    -- Cleanup temp tables
    DROP TABLE IF EXISTS temp_day_trips;

    -- Return results
    RETURN QUERY
    SELECT
        cg.id AS carpool_group_id,
        (SELECT COUNT(*)::INTEGER FROM carpool_members cm WHERE cm.carpool_group_id = cg.id) AS member_count,
        cg.driver_employee_id,
        cg.review_needed
    FROM carpool_groups cg
    WHERE cg.trip_date = p_date;
END;
$$;

-- =========================================================================
-- Section E: Fix get_mileage_summary (base: migration 068)
-- =========================================================================

CREATE OR REPLACE FUNCTION get_mileage_summary(
    p_employee_id UUID,
    p_period_start DATE,
    p_period_end DATE
)
RETURNS TABLE (
    total_distance_km DECIMAL(10, 3),
    business_distance_km DECIMAL(10, 3),
    personal_distance_km DECIMAL(10, 3),
    trip_count INTEGER,
    business_trip_count INTEGER,
    personal_trip_count INTEGER,
    estimated_reimbursement DECIMAL(10, 2),
    rate_per_km_used DECIMAL(5, 4),
    rate_source TEXT,
    ytd_business_km DECIMAL(10, 3)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_total_km DECIMAL(10, 3) := 0;
    v_business_km DECIMAL(10, 3) := 0;
    v_personal_km DECIMAL(10, 3) := 0;
    v_total_count INTEGER := 0;
    v_business_count INTEGER := 0;
    v_personal_count INTEGER := 0;
    v_reimbursement DECIMAL(10, 2) := 0;
    v_rate DECIMAL(5, 4) := 0;
    v_rate_src TEXT := 'none';
    v_ytd_km DECIMAL(10, 3) := 0;
    v_threshold INTEGER;
    v_rate_after DECIMAL(5, 4);
    v_ytd_before DECIMAL(10, 3) := 0;
    v_period_year INTEGER;
BEGIN
    v_period_year := EXTRACT(YEAR FROM p_period_end);

    -- Aggregate trips for the period
    SELECT
        COALESCE(SUM(COALESCE(t.road_distance_km, t.distance_km)), 0),
        COALESCE(SUM(CASE
            WHEN t.classification = 'business'
                 AND t.transport_mode = 'driving'
                 AND NOT has_active_vehicle_period(t.employee_id, 'company', to_business_date(t.started_at))
                 AND (
                     NOT EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id)
                     OR EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id AND cm.role = 'driver')
                 )
            THEN COALESCE(t.road_distance_km, t.distance_km)
            ELSE 0
        END), 0),
        COALESCE(SUM(CASE WHEN t.classification = 'personal' THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
        COUNT(*)::INTEGER,
        COUNT(CASE
            WHEN t.classification = 'business'
                 AND t.transport_mode = 'driving'
                 AND NOT has_active_vehicle_period(t.employee_id, 'company', to_business_date(t.started_at))
                 AND (
                     NOT EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id)
                     OR EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id AND cm.role = 'driver')
                 )
            THEN 1
        END)::INTEGER,
        COUNT(CASE WHEN t.classification = 'personal' THEN 1 END)::INTEGER
    INTO v_total_km, v_business_km, v_personal_km, v_total_count, v_business_count, v_personal_count
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.started_at >= business_day_start(p_period_start)
      AND t.started_at < business_day_end(p_period_end);

    -- Calculate YTD business km
    SELECT COALESCE(SUM(CASE
        WHEN t.classification = 'business'
             AND t.transport_mode = 'driving'
             AND NOT has_active_vehicle_period(t.employee_id, 'company', to_business_date(t.started_at))
             AND (
                 NOT EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id)
                 OR EXISTS (SELECT 1 FROM carpool_members cm WHERE cm.trip_id = t.id AND cm.role = 'driver')
             )
        THEN COALESCE(t.road_distance_km, t.distance_km)
        ELSE 0
    END), 0)
    INTO v_ytd_km
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.started_at >= business_day_start((v_period_year || '-01-01')::DATE)
      AND t.started_at < business_day_end(p_period_end);

    v_ytd_before := v_ytd_km - v_business_km;

    -- Lookup reimbursement rate
    SELECT r.rate_per_km, r.threshold_km, r.rate_after_threshold, r.rate_source
    INTO v_rate, v_threshold, v_rate_after, v_rate_src
    FROM reimbursement_rates r
    WHERE r.effective_from <= p_period_end
      AND (r.effective_to IS NULL OR r.effective_to >= p_period_end)
    ORDER BY r.effective_from DESC
    LIMIT 1;

    -- Calculate reimbursement with tiered rates
    IF v_rate > 0 AND v_business_km > 0 THEN
        IF v_threshold IS NOT NULL AND v_rate_after IS NOT NULL THEN
            IF v_ytd_before >= v_threshold THEN
                v_reimbursement := v_business_km * v_rate_after;
            ELSIF (v_ytd_before + v_business_km) <= v_threshold THEN
                v_reimbursement := v_business_km * v_rate;
            ELSE
                v_reimbursement :=
                    (v_threshold - v_ytd_before) * v_rate +
                    (v_business_km - (v_threshold - v_ytd_before)) * v_rate_after;
            END IF;
        ELSE
            v_reimbursement := v_business_km * v_rate;
        END IF;
    END IF;

    RETURN QUERY SELECT
        v_total_km,
        v_business_km,
        v_personal_km,
        v_total_count,
        v_business_count,
        v_personal_count,
        ROUND(v_reimbursement, 2),
        COALESCE(v_rate, 0::DECIMAL(5,4)),
        COALESCE(v_rate_src, 'none'),
        v_ytd_km;
END;
$$;

-- =========================================================================
-- Section F: Fix get_cleaning_dashboard (base: migration 016)
-- =========================================================================

CREATE OR REPLACE FUNCTION get_cleaning_dashboard(
  p_building_id UUID DEFAULT NULL,
  p_employee_id UUID DEFAULT NULL,
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE,
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
  v_summary JSONB;
  v_sessions JSONB;
  v_total_count INT;
BEGIN
  -- Summary aggregation
  SELECT jsonb_build_object(
    'total_sessions', COUNT(*),
    'completed', COUNT(*) FILTER (WHERE cs.status = 'completed'),
    'in_progress', COUNT(*) FILTER (WHERE cs.status = 'in_progress'),
    'auto_closed', COUNT(*) FILTER (WHERE cs.status = 'auto_closed'),
    'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1),
    'flagged_count', COUNT(*) FILTER (WHERE cs.is_flagged = true)
  )
  INTO v_summary
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  WHERE to_business_date(cs.started_at) BETWEEN p_date_from AND p_date_to
    AND (p_building_id IS NULL OR s.building_id = p_building_id)
    AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id);

  -- Total count for pagination
  SELECT COUNT(*)
  INTO v_total_count
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  WHERE to_business_date(cs.started_at) BETWEEN p_date_from AND p_date_to
    AND (p_building_id IS NULL OR s.building_id = p_building_id)
    AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id);

  -- Paginated sessions
  SELECT COALESCE(jsonb_agg(row_data), '[]'::JSONB)
  INTO v_sessions
  FROM (
    SELECT jsonb_build_object(
      'id', cs.id,
      'employee_id', cs.employee_id,
      'employee_name', COALESCE(ep.full_name, ep.email),
      'studio_id', cs.studio_id,
      'studio_number', s.studio_number,
      'building_name', b.name,
      'studio_type', s.studio_type,
      'shift_id', cs.shift_id,
      'status', cs.status,
      'started_at', cs.started_at,
      'completed_at', cs.completed_at,
      'duration_minutes', cs.duration_minutes,
      'is_flagged', cs.is_flagged,
      'flag_reason', cs.flag_reason
    ) AS row_data
    FROM cleaning_sessions cs
    JOIN studios s ON cs.studio_id = s.id
    JOIN buildings b ON s.building_id = b.id
    JOIN employee_profiles ep ON cs.employee_id = ep.id
    WHERE to_business_date(cs.started_at) BETWEEN p_date_from AND p_date_to
      AND (p_building_id IS NULL OR s.building_id = p_building_id)
      AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id)
    ORDER BY cs.started_at DESC
    LIMIT p_limit OFFSET p_offset
  ) sub;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'sessions', v_sessions,
    'total_count', v_total_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Also fix get_cleaning_stats_by_building
CREATE OR REPLACE FUNCTION get_cleaning_stats_by_building(
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE
) RETURNS JSONB AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(row_data), '[]'::JSONB)
    FROM (
      SELECT jsonb_build_object(
        'building_id', b.id,
        'building_name', b.name,
        'total_studios', (SELECT COUNT(*) FROM studios WHERE building_id = b.id AND is_active = true),
        'cleaned_today', COUNT(DISTINCT cs.studio_id) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')),
        'in_progress', COUNT(*) FILTER (WHERE cs.status = 'in_progress'),
        'not_started', (SELECT COUNT(*) FROM studios WHERE building_id = b.id AND is_active = true) - COUNT(DISTINCT cs.studio_id),
        'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1)
      ) AS row_data
      FROM buildings b
      LEFT JOIN studios s ON s.building_id = b.id AND s.is_active = true
      LEFT JOIN cleaning_sessions cs ON cs.studio_id = s.id
        AND to_business_date(cs.started_at) BETWEEN p_date_from AND p_date_to
      GROUP BY b.id, b.name
      ORDER BY b.name
    ) sub
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Also fix get_employee_cleaning_stats
CREATE OR REPLACE FUNCTION get_employee_cleaning_stats(
  p_employee_id UUID DEFAULT NULL,
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE
) RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'employee_name', COALESCE(ep.full_name, ep.email),
    'total_sessions', COUNT(cs.id),
    'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1),
    'sessions_by_building', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'building_name', b2.name,
        'count', sub.cnt,
        'avg_duration', sub.avg_dur
      )), '[]'::JSONB)
      FROM (
        SELECT s2.building_id, COUNT(*) AS cnt, ROUND(COALESCE(AVG(cs2.duration_minutes), 0), 1) AS avg_dur
        FROM cleaning_sessions cs2
        JOIN studios s2 ON cs2.studio_id = s2.id
        WHERE cs2.employee_id = ep.id
          AND to_business_date(cs2.started_at) BETWEEN p_date_from AND p_date_to
        GROUP BY s2.building_id
      ) sub
      JOIN buildings b2 ON sub.building_id = b2.id
    ),
    'flagged_sessions', COUNT(cs.id) FILTER (WHERE cs.is_flagged = true)
  )
  INTO v_result
  FROM employee_profiles ep
  LEFT JOIN cleaning_sessions cs ON cs.employee_id = ep.id
    AND to_business_date(cs.started_at) BETWEEN p_date_from AND p_date_to
  WHERE (p_employee_id IS NULL OR ep.id = p_employee_id)
  GROUP BY ep.id, ep.full_name, ep.email;

  RETURN COALESCE(v_result, '{}'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
