-- =============================================================================
-- 130: Untracked time gaps — detect and display GPS gaps in approval timeline
-- =============================================================================
-- For each completed shift, walks the timeline from clock-in to clock-out and
-- emits synthetic 'gap' activities wherever no stop or trip covers a period > 5 min.
-- Gaps get deterministic UUIDs so overrides persist across recalculations.
-- =============================================================================

-- =========================================================================
-- Part 1: Schema — Allow 'gap' activity type in overrides
-- =========================================================================
ALTER TABLE activity_overrides
  DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides
  ADD CONSTRAINT activity_overrides_activity_type_check
  CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap'));

-- =========================================================================
-- Part 2: Updated save_activity_override (add 'gap' to validation)
-- =========================================================================
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_day_approval_id UUID;
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid override status: %. Must be approved or rejected', p_status;
    END IF;

    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot override activities on an already approved day';
    END IF;

    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING
    RETURNING id INTO v_day_approval_id;

    IF v_day_approval_id IS NULL THEN
        SELECT id INTO v_day_approval_id
        FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date;
    END IF;

    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =========================================================================
-- Part 3: Updated get_day_approval_detail with gap detection
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
    WITH shift_boundaries AS (
        SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    activity_data AS (
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
          AND sc.shift_id IN (SELECT shift_id FROM shift_boundaries)

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
          AND t.shift_id IN (SELECT shift_id FROM shift_boundaries)

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
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    -- Gap detection: find periods within completed shifts not covered by stops or trips
    real_activities AS (
        SELECT ad.shift_id, ad.started_at, ad.ended_at
        FROM activity_data ad
        WHERE ad.activity_type IN ('stop', 'trip')
    ),
    shift_events AS (
        -- Shift start boundary
        SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
        FROM shift_boundaries sb
        UNION ALL
        -- Activity start (marks end of potential gap)
        SELECT ra.shift_id, ra.started_at, 2
        FROM real_activities ra
        UNION ALL
        -- Activity end (marks start of potential gap)
        SELECT ra.shift_id, ra.ended_at, 1
        FROM real_activities ra
        UNION ALL
        -- Shift end boundary
        SELECT sb.shift_id, sb.clocked_out_at, 3
        FROM shift_boundaries sb
    ),
    ordered_events AS (
        SELECT
            shift_id,
            event_time,
            event_order,
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
        WHERE e1.event_order IN (0, 1) -- shift_start or activity_end
          AND e2.event_order IN (2, 3) -- activity_start or shift_end
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
    -- Handle shifts with zero activities
    empty_shift_gaps AS (
        SELECT
            sb.shift_id,
            sb.clocked_in_at AS gap_started_at,
            sb.clocked_out_at AS gap_ended_at,
            EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at))::INTEGER AS gap_seconds
        FROM shift_boundaries sb
        WHERE NOT EXISTS (
            SELECT 1 FROM real_activities ra WHERE ra.shift_id = sb.shift_id
        )
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
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            0::INTEGER AS gps_gap_seconds,
            0::INTEGER AS gps_gap_count,
            'needs_review'::TEXT AS auto_status,
            'Temps non suivi'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
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
            'needs_review_count', v_needs_review_count
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =========================================================================
-- Part 4: Updated get_weekly_approval_summary with gap classification
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
            s.clocked_in_at::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, s.clocked_in_at::DATE
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Shift boundaries for gap detection
    completed_shifts AS (
        SELECT s.id AS shift_id, s.employee_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    -- Real activities (stops + trips) for gap detection
    shift_real_activities AS (
        SELECT sc.shift_id, sc.started_at, sc.ended_at
        FROM stationary_clusters sc
        WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180
        UNION ALL
        SELECT t.shift_id, t.started_at, t.ended_at
        FROM trips t
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Build timeline events per shift
    gap_shift_events AS (
        SELECT cs.shift_id, cs.employee_id, cs.clocked_in_at AS event_time, 0 AS event_order
        FROM completed_shifts cs
        UNION ALL
        SELECT ra.shift_id, cs.employee_id, ra.started_at, 2
        FROM shift_real_activities ra
        JOIN completed_shifts cs ON cs.shift_id = ra.shift_id
        UNION ALL
        SELECT ra.shift_id, cs.employee_id, ra.ended_at, 1
        FROM shift_real_activities ra
        JOIN completed_shifts cs ON cs.shift_id = ra.shift_id
        UNION ALL
        SELECT cs.shift_id, cs.employee_id, cs.clocked_out_at, 3
        FROM completed_shifts cs
    ),
    gap_ordered_events AS (
        SELECT
            shift_id, employee_id, event_time, event_order,
            ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY event_time, event_order) AS rn
        FROM gap_shift_events
    ),
    gap_pairs AS (
        SELECT
            e1.shift_id,
            e1.employee_id,
            e1.event_time AS gap_started_at,
            e2.event_time AS gap_ended_at,
            EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
        FROM gap_ordered_events e1
        JOIN gap_ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
        WHERE e1.event_order IN (0, 1)
          AND e2.event_order IN (2, 3)
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
    empty_shift_gaps AS (
        SELECT
            cs.shift_id,
            cs.employee_id,
            cs.clocked_in_at AS gap_started_at,
            cs.clocked_out_at AS gap_ended_at,
            EXTRACT(EPOCH FROM (cs.clocked_out_at - cs.clocked_in_at))::INTEGER AS gap_seconds
        FROM completed_shifts cs
        WHERE NOT EXISTS (
            SELECT 1 FROM shift_real_activities ra WHERE ra.shift_id = cs.shift_id
        )
        AND EXTRACT(EPOCH FROM (cs.clocked_out_at - cs.clocked_in_at)) > 300
    ),
    all_weekly_gaps AS (
        SELECT * FROM gap_pairs
        UNION ALL
        SELECT * FROM empty_shift_gaps
    ),
    -- Live classification of stops, trips, AND gaps for non-approved days
    live_activity_classification AS (
        -- Stops (same rules as get_day_approval_detail migration 122)
        SELECT
            sc.employee_id,
            sc.started_at::DATE AS activity_date,
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
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = sc.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
        WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180

        UNION ALL

        -- Trips with cluster-based location fallback (same as migration 122)
        SELECT
            t.employee_id,
            t.started_at::DATE,
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
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)

        UNION ALL

        -- Gaps (untracked time within shifts)
        SELECT
            g.employee_id,
            g.gap_started_at::DATE AS activity_date,
            (g.gap_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status, 'needs_review') AS final_status
        FROM all_weekly_gaps g
        LEFT JOIN day_approvals da ON da.employee_id = g.employee_id AND da.date = g.gap_started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'gap'
            AND ao.activity_id = md5(g.employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID
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
