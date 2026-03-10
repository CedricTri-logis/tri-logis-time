-- Add call_bonus_minutes to both approval RPCs
-- This is the extra time added by the 3h minimum rule (Article 58 LNT)
-- e.g., a 48-min callback shift billed at 3h → bonus = 132 min

-- =========================================================================
-- 1. Update _get_day_approval_detail_base — add call_bonus_minutes
-- =========================================================================

CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_lunch_minutes INTEGER := 0;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
    v_call_count INTEGER := 0;
    v_call_billed_minutes INTEGER := 0;
    v_call_bonus_minutes INTEGER := 0;
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

    -- Calculate lunch minutes for this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.started_at::DATE = p_date
      AND lb.ended_at IS NOT NULL;

    -- Subtract lunch from total shift minutes
    v_total_shift_minutes := GREATEST(v_total_shift_minutes - v_lunch_minutes, 0);

    -- Calculate call billing with grouping logic (Article 58 LNT)
    WITH call_shifts_ordered AS (
        SELECT
            id,
            clocked_in_at,
            clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY clocked_in_at) AS rn
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND shift_type = 'call'
          AND status = 'completed'
    ),
    call_with_groups AS (
        SELECT
            cs.*,
            SUM(CASE
                WHEN cs.rn = 1 THEN 1
                WHEN cs.clocked_in_at >= (
                    SELECT GREATEST(
                        prev.clocked_in_at + INTERVAL '3 hours',
                        COALESCE(prev.clocked_out_at, prev.clocked_in_at + INTERVAL '3 hours')
                    )
                    FROM call_shifts_ordered prev
                    WHERE prev.rn = cs.rn - 1
                ) THEN 1
                ELSE 0
            END) OVER (ORDER BY cs.rn) AS group_id
        FROM call_shifts_ordered cs
    ),
    call_group_billing AS (
        SELECT
            group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(
                EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
                180
            )::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM call_with_groups
        GROUP BY group_id
    )
    SELECT
        COALESCE(SUM(shifts_in_group), 0)::INTEGER,
        COALESCE(SUM(group_billed_minutes), 0)::INTEGER,
        COALESCE(SUM(group_bonus_minutes), 0)::INTEGER
    INTO v_call_count, v_call_billed_minutes, v_call_bonus_minutes
    FROM call_group_billing;

    -- Build classified activity list
    WITH stop_data AS (
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
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                ELSE 'Lieu non autorisé (inconnu)'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180
    ),
    stop_classified AS (
        SELECT
            sd.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, sd.auto_status) AS final_status
        FROM stop_data sd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sd.activity_id
    ),
    trip_data AS (
        SELECT
            'trip'::TEXT AS activity_type,
            t.id AS activity_id,
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
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                        ELSE 'needs_review'
                    END
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                            CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                            CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        ELSE 'Données GPS incomplètes'
                    END
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                    CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                    CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                ELSE 'À vérifier'
            END AS auto_reason,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            COALESCE(t.start_location_id, dep_cluster.matched_location_id) AS start_location_id,
            COALESCE(sl.name, dep_loc.name)::TEXT AS start_location_name,
            COALESCE(sl.location_type, dep_loc.location_type)::TEXT AS start_location_type,
            COALESCE(t.end_location_id, arr_cluster.matched_location_id) AS end_location_id,
            COALESCE(el.name, arr_loc.name)::TEXT AS end_location_name,
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
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
        LEFT JOIN LATERAL (
            SELECT sc_dep.final_status
            FROM stop_classified sc_dep
            WHERE sc_dep.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_dep.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT sc_arr.final_status
            FROM stop_classified sc_arr
            WHERE sc_arr.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_arr.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    ),
    clock_data AS (
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL AS latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu non autorisé'
                ELSE 'Clock-in lieu non autorisé'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            s.shift_type::TEXT AS shift_type,
            s.shift_type_source::TEXT AS shift_type_source
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
            NULL::INTEGER,
            NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu non autorisé'
                ELSE 'Clock-out lieu non autorisé'
            END,
            NULL::DECIMAL,
            NULL::TEXT,
            NULL::BOOLEAN,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            s.shift_type::TEXT,
            s.shift_type_source::TEXT
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
    -- Lunch breaks as activities
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            lb.id AS activity_id,
            lb.shift_id,
            lb.started_at,
            lb.ended_at,
            (EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'approved'::TEXT AS auto_status,
            'Pause dîner'::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            'approved'::TEXT AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.started_at::DATE = p_date
          AND lb.ended_at IS NOT NULL
    ),
    classified AS (
        SELECT
            sc.activity_type, sc.activity_id, sc.shift_id,
            sc.started_at, sc.ended_at, sc.duration_minutes,
            sc.matched_location_id, sc.location_name, sc.location_type,
            sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
            sc.auto_status, sc.auto_reason,
            sc.override_status, sc.override_reason, sc.final_status,
            sc.distance_km, sc.transport_mode, sc.has_gps_gap,
            sc.start_location_id, sc.start_location_name, sc.start_location_type,
            sc.end_location_id, sc.end_location_name, sc.end_location_type,
            sc.shift_type, sc.shift_type_source
        FROM stop_classified sc

        UNION ALL

        SELECT
            td.activity_type, td.activity_id, td.shift_id,
            td.started_at, td.ended_at, td.duration_minutes,
            td.matched_location_id, td.location_name, td.location_type,
            td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
            td.auto_status, td.auto_reason,
            tao.override_status, tao.reason AS override_reason,
            COALESCE(tao.override_status, td.auto_status) AS final_status,
            td.distance_km, td.transport_mode, td.has_gps_gap,
            td.start_location_id, td.start_location_name, td.start_location_type,
            td.end_location_id, td.end_location_name, td.end_location_type,
            td.shift_type, td.shift_type_source
        FROM trip_data td
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao ON tao.day_approval_id = da.id
            AND tao.activity_type = 'trip' AND tao.activity_id = td.activity_id

        UNION ALL

        SELECT
            cd.activity_type, cd.activity_id, cd.shift_id,
            cd.started_at, cd.ended_at, cd.duration_minutes,
            cd.matched_location_id, cd.location_name, cd.location_type,
            cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
            cd.auto_status, cd.auto_reason,
            cao.override_status, cao.reason AS override_reason,
            COALESCE(cao.override_status, cd.auto_status) AS final_status,
            cd.distance_km, cd.transport_mode, cd.has_gps_gap,
            cd.start_location_id, cd.start_location_name, cd.start_location_type,
            cd.end_location_id, cd.end_location_name, cd.end_location_type,
            cd.shift_type, cd.shift_type_source
        FROM clock_data cd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao ON cao.day_approval_id = da.id
            AND cao.activity_type = cd.activity_type AND cao.activity_id = cd.activity_id

        UNION ALL

        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source
        FROM lunch_data ld

        ORDER BY started_at ASC
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
            'gps_gap_count', c.gps_gap_count,
            'shift_type', c.shift_type,
            'shift_type_source', c.shift_type_source
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- Compute summary
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' != 'lunch'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out', 'lunch')
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

    -- If day is already approved, use frozen totals
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

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
            'lunch_minutes', v_lunch_minutes,
            'call_count', v_call_count,
            'call_billed_minutes', v_call_billed_minutes,
            'call_bonus_minutes', v_call_bonus_minutes
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- =========================================================================
-- 2. Update get_weekly_approval_summary — add call_bonus_minutes
-- =========================================================================

CREATE OR REPLACE FUNCTION get_weekly_approval_summary(
    p_week_start DATE
)
RETURNS JSONB AS $$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
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
    day_lunch AS (
        SELECT
            lb.employee_id,
            lb.started_at::DATE AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM lunch_breaks lb
        WHERE lb.ended_at IS NOT NULL
          AND lb.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND lb.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY lb.employee_id, lb.started_at::DATE
    ),
    day_calls_lagged AS (
        SELECT
            employee_id,
            clocked_in_at::DATE AS call_date,
            clocked_in_at,
            clocked_out_at,
            LAG(clocked_in_at) OVER w AS prev_clocked_in_at,
            LAG(clocked_out_at) OVER w AS prev_clocked_out_at
        FROM shifts
        WHERE shift_type = 'call'
          AND status = 'completed'
          AND clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND employee_id IN (SELECT employee_id FROM employee_list)
        WINDOW w AS (PARTITION BY employee_id, clocked_in_at::DATE ORDER BY clocked_in_at)
    ),
    day_calls AS (
        SELECT
            employee_id,
            call_date,
            clocked_in_at,
            clocked_out_at,
            SUM(CASE
                WHEN prev_clocked_in_at IS NULL THEN 1
                WHEN clocked_in_at >= GREATEST(
                    prev_clocked_in_at + INTERVAL '3 hours',
                    prev_clocked_out_at
                ) THEN 1
                ELSE 0
            END) OVER (PARTITION BY employee_id, call_date ORDER BY clocked_in_at) AS group_id
        FROM day_calls_lagged
    ),
    day_call_groups AS (
        SELECT
            employee_id,
            call_date,
            group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(
                EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
                180
            )::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM day_calls
        GROUP BY employee_id, call_date, group_id
    ),
    day_call_totals AS (
        SELECT
            employee_id,
            call_date,
            SUM(shifts_in_group)::INTEGER AS call_count,
            SUM(group_billed_minutes)::INTEGER AS call_billed_minutes,
            SUM(group_bonus_minutes)::INTEGER AS call_bonus_minutes
        FROM day_call_groups
        GROUP BY employee_id, call_date
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_stop_classification AS (
        SELECT
            sc.employee_id,
            sc.started_at::DATE AS activity_date,
            sc.id AS activity_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
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
    ),
    live_trip_classification AS (
        SELECT
            t.employee_id,
            t.started_at::DATE AS activity_date,
            t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN t.has_gps_gap = TRUE THEN
                        CASE
                            WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                            WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                            WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                            WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                            ELSE 'needs_review'
                        END
                    WHEN t.duration_minutes > 60 THEN 'needs_review'
                    WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                    WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                    WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                    WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_stop_classification ls
            WHERE ls.employee_id = t.employee_id
              AND ls.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_stop_classification ls
            WHERE ls.employee_id = t.employee_id
              AND ls.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_activity_classification AS (
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_stop_classification
        UNION ALL
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_trip_classification
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
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes,
            COALESCE(dct.call_count, 0) AS call_count,
            COALESCE(dct.call_billed_minutes, 0) AS call_billed_minutes,
            COALESCE(dct.call_bonus_minutes, 0) AS call_bonus_minutes
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt
            ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
        LEFT JOIN day_lunch dl
            ON dl.employee_id = ds.employee_id AND dl.lunch_date = ds.shift_date
        LEFT JOIN day_call_totals dct
            ON dct.employee_id = ds.employee_id AND dct.call_date = ds.shift_date
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
                        'lunch_minutes', COALESCE(pds.lunch_minutes, 0),
                        'call_count', COALESCE(pds.call_count, 0),
                        'call_billed_minutes', COALESCE(pds.call_billed_minutes, 0),
                        'call_bonus_minutes', COALESCE(pds.call_bonus_minutes, 0)
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
