-- Migration: Include manual_time_entries in _get_day_approval_detail_base
-- Also update save_activity_override and remove_activity_override to accept 'manual_time'

-- =====================================================================
-- 1) UPDATE _get_day_approval_detail_base
-- =====================================================================
CREATE OR REPLACE FUNCTION public._get_day_approval_detail_base(p_employee_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_gaps JSONB;
    v_gap_segments JSONB;
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

    -- Calculate total shift minutes using effective times (exclude lunch segments)
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, now()) - est.effective_clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts s
    CROSS JOIN LATERAL effective_shift_times(s.id) est
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at::DATE = p_date
      AND s.status = 'completed'
      AND NOT s.is_lunch;

    -- Add standalone manual_time_entries to total shift minutes
    v_total_shift_minutes := v_total_shift_minutes + COALESCE((
        SELECT SUM(EXTRACT(EPOCH FROM (ends_at - starts_at)) / 60)::INTEGER
        FROM manual_time_entries
        WHERE employee_id = p_employee_id AND date = p_date AND shift_id IS NULL
    ), 0);

    -- Calculate lunch minutes from lunch shift segments
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
      AND s.clocked_out_at IS NOT NULL;

    -- NOTE: No lunch subtraction needed — lunch is already excluded from v_total_shift_minutes

    -- Calculate call billing with grouping logic (Article 58 LNT)
    WITH call_shifts_ordered AS (
        SELECT
            s.id,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY est.effective_clocked_in_at) AS rn
        FROM shifts s, effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.shift_type = 'call'
          AND s.status = 'completed'
          AND s.is_lunch = false
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
            NULL::DECIMAL AS road_distance_km,
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
          -- Exclude stops from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    stop_classified AS (
        SELECT
            sd.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, sd.auto_status) AS final_status,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value
        FROM stop_data sd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sd.activity_id
    ),
    -- Segment data for segmented clusters — now uses activity_segments (universal table)
    segment_data AS (
        SELECT
            'stop_segment'::TEXT AS activity_type,
            aseg.id AS activity_id,
            sc.shift_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
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
            NULL::DECIMAL AS road_distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                ELSE 'rejected'
            END) AS final_status,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value
        FROM activity_segments aseg
        JOIN stationary_clusters sc ON sc.id = aseg.activity_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id
            AND da.date = to_business_date(aseg.starts_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment'
            AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'stop'
          AND sc.employee_id = p_employee_id
          AND aseg.starts_at >= p_date::TIMESTAMPTZ
          AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude segments from lunch shifts
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    -- Union: non-segmented stops + segments (exclude segmented parents)
    all_stops AS (
        SELECT * FROM stop_classified
        WHERE activity_id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'stop')
        UNION ALL
        SELECT * FROM segment_data
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
                -- GPS gap handling
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                        WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                        ELSE 'needs_review'
                    END
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                -- GPS gap handling
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'Trajet de commute'
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'Trajet de commute'
                        WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'Destination inconnue'
                        ELSE 'Données GPS incomplètes'
                    END
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'Trajet de commute'
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'Trajet de commute'
                WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'Destination inconnue'
                ELSE 'À vérifier'
            END AS auto_reason,
            t.distance_km,
            t.road_distance_km,
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
        -- Adjacent stop status uses all_stops (includes segments)
        LEFT JOIN LATERAL (
            SELECT sc_dep.final_status
            FROM all_stops sc_dep
            WHERE sc_dep.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_dep.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT sc_arr.final_status
            FROM all_stops sc_arr
            WHERE sc_arr.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_arr.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude trips from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = t.shift_id AND sl.is_lunch = true)
          -- Exclude segmented parent trips
          AND t.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'trip')
    ),
    -- Trip segments: segments of trips that have been split
    trip_segment_data AS (
        SELECT
            'trip_segment'::TEXT AS activity_type,
            aseg.id AS activity_id,
            t.shift_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            -- First GPS point latitude/longitude within the segment window
            COALESCE(first_gps.latitude, t.start_latitude) AS latitude,
            COALESCE(first_gps.longitude, t.start_longitude) AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'needs_review'::TEXT AS auto_status,
            'Segment de trajet'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, 'needs_review') AS final_status,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value
        FROM activity_segments aseg
        JOIN trips t ON t.id = aseg.activity_id
        LEFT JOIN LATERAL (
            SELECT gp.latitude, gp.longitude
            FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = t.id
              AND gp.captured_at >= aseg.starts_at
              AND gp.captured_at < aseg.ends_at
            ORDER BY gp.captured_at ASC
            LIMIT 1
        ) first_gps ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id
            AND da.date = to_business_date(aseg.starts_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip_segment'
            AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'trip'
          AND t.employee_id = p_employee_id
          AND aseg.starts_at >= p_date::TIMESTAMPTZ
          AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude segments from lunch shifts
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = t.shift_id AND sl.is_lunch = true)
    ),
    -- Clock data with effective times and edit indicators
    clock_data AS (
        -- Clock-in events: only first segment (not post-lunch)
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            est.effective_clocked_in_at AS started_at,
            est.effective_clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL AS latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN s.clock_in_location IS NULL THEN 'needs_review'
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN s.clock_in_location IS NULL THEN 'Clock-in sans GPS'
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu non autorisé'
                ELSE 'Clock-in lieu non autorisé'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            s.shift_type::TEXT AS shift_type,
            s.shift_type_source::TEXT AS shift_type_source,
            est.clock_in_edited AS is_edited,
            CASE WHEN est.clock_in_edited THEN s.clocked_in_at ELSE NULL END AS original_value
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
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
          AND NOT s.is_lunch
          -- Only show clock-in from the first segment (not post-lunch resumptions)
          AND (s.work_body_id IS NULL OR s.clocked_in_at = (
            SELECT MIN(s2.clocked_in_at) FROM shifts s2 WHERE s2.work_body_id = s.work_body_id
          ))

        UNION ALL

        -- Clock-out events: only from non-lunch, non-lunch-split segments
        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            est.effective_clocked_out_at,
            est.effective_clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER,
            NULL::INTEGER,
            CASE
                WHEN s.clock_out_location IS NULL AND s.clock_out_reason = 'midnight_auto_close' THEN 'needs_review'
                WHEN s.clock_out_location IS NULL THEN 'needs_review'
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END,
            CASE
                WHEN s.clock_out_reason = 'midnight_auto_close' THEN 'Clock-out automatique (minuit)'
                WHEN s.clock_out_location IS NULL THEN 'Clock-out sans GPS'
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu non autorisé'
                ELSE 'Clock-out lieu non autorisé'
            END,
            NULL::DECIMAL,
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
            s.shift_type_source::TEXT,
            est.clock_out_edited AS is_edited,
            CASE WHEN est.clock_out_edited THEN s.clocked_out_at ELSE NULL END AS original_value
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
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
          AND NOT s.is_lunch
          -- Exclude clock-outs that are lunch splits (reason = 'lunch' or 'lunch_end')
          AND COALESCE(s.clock_out_reason, '') NOT IN ('lunch', 'lunch_end')
    ),
    -- Lunch data: from lunch shift segments with children
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_out_at AS ended_at,
            (EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'rejected'::TEXT AS auto_status,
            'Pause dîner (non payée)'::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            'rejected'::TEXT AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            -- Children: stops and trips during lunch
            (SELECT jsonb_agg(child ORDER BY child->>'started_at')
             FROM (
               SELECT jsonb_build_object(
                 'activity_id', sc.id,
                 'activity_type', 'stop',
                 'started_at', sc.started_at,
                 'ended_at', sc.ended_at,
                 'duration_minutes', sc.duration_seconds / 60,
                 'auto_status', 'rejected',
                 'auto_reason', 'Pendant la pause dîner',
                 'location_name', l.name,
                 'location_type', l.location_type::TEXT,
                 'latitude', sc.centroid_latitude,
                 'longitude', sc.centroid_longitude
               ) AS child
               FROM stationary_clusters sc
               LEFT JOIN locations l ON l.id = sc.matched_location_id
               WHERE sc.shift_id = s.id AND sc.duration_seconds >= 180
               UNION ALL
               SELECT jsonb_build_object(
                 'activity_id', t.id,
                 'activity_type', 'trip',
                 'started_at', t.started_at,
                 'ended_at', t.ended_at,
                 'duration_minutes', t.duration_minutes,
                 'distance_km', COALESCE(t.road_distance_km, t.distance_km),
                 'auto_status', 'rejected',
                 'auto_reason', 'Pendant la pause dîner',
                 'transport_mode', t.transport_mode::TEXT,
                 'start_location_name', sl2.name,
                 'end_location_name', el2.name
               ) AS child
               FROM trips t
               LEFT JOIN locations sl2 ON sl2.id = t.start_location_id
               LEFT JOIN locations el2 ON el2.id = t.end_location_id
               WHERE t.shift_id = s.id
             ) sub
            ) AS children
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
          AND s.clocked_out_at IS NOT NULL
    ),
    -- Manual time entries data
    manual_time_data AS (
        SELECT
            'manual_time'::TEXT AS activity_type,
            mte.id AS activity_id,
            COALESCE(mte.shift_id, mte.id) AS shift_id,
            mte.starts_at AS started_at,
            mte.ends_at AS ended_at,
            CASE WHEN mte.shift_id IS NOT NULL THEN 0
                 ELSE EXTRACT(EPOCH FROM (mte.ends_at - mte.starts_at))::INT / 60
            END AS duration_minutes,
            mte.location_id AS matched_location_id,
            l.name AS location_name,
            l.location_type::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'needs_review'::TEXT AS auto_status,
            'Temps manuel ajouté'::TEXT AS auto_reason,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, 'needs_review') AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            mte.reason AS manual_reason,
            (mte.shift_id IS NULL) AS is_standalone_shift,
            ep.full_name AS manual_created_by_name,
            mte.created_at AS manual_created_at
        FROM manual_time_entries mte
        LEFT JOIN locations l ON l.id = mte.location_id
        LEFT JOIN employee_profiles ep ON ep.id = mte.created_by
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'manual_time' AND ao.activity_id = mte.id
        WHERE mte.employee_id = p_employee_id
          AND mte.date = p_date
    ),
    classified AS (
        -- Stops (non-segmented + segments)
        SELECT
            sc.activity_type, sc.activity_id, sc.shift_id,
            sc.started_at, sc.ended_at, sc.duration_minutes,
            sc.matched_location_id, sc.location_name, sc.location_type,
            sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
            sc.auto_status, sc.auto_reason,
            sc.override_status, sc.override_reason, sc.final_status,
            sc.distance_km, sc.road_distance_km, sc.transport_mode, sc.has_gps_gap,
            sc.start_location_id, sc.start_location_name, sc.start_location_type,
            sc.end_location_id, sc.end_location_name, sc.end_location_type,
            sc.shift_type, sc.shift_type_source,
            sc.is_edited, sc.original_value,
            NULL::JSONB AS children,
            NULL::TEXT AS manual_reason,
            NULL::BOOLEAN AS is_standalone_shift,
            NULL::TEXT AS manual_created_by,
            NULL::TIMESTAMPTZ AS manual_created_at
        FROM all_stops sc

        UNION ALL

        -- Trips (non-segmented)
        SELECT
            td.activity_type, td.activity_id, td.shift_id,
            td.started_at, td.ended_at, td.duration_minutes,
            td.matched_location_id, td.location_name, td.location_type,
            td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
            td.auto_status, td.auto_reason,
            tao.override_status, tao.reason AS override_reason,
            COALESCE(tao.override_status, td.auto_status) AS final_status,
            td.distance_km, td.road_distance_km, td.transport_mode, td.has_gps_gap,
            td.start_location_id, td.start_location_name, td.start_location_type,
            td.end_location_id, td.end_location_name, td.end_location_type,
            td.shift_type, td.shift_type_source,
            FALSE AS is_edited, NULL::TIMESTAMPTZ AS original_value,
            NULL::JSONB AS children,
            NULL::TEXT AS manual_reason,
            NULL::BOOLEAN AS is_standalone_shift,
            NULL::TEXT AS manual_created_by,
            NULL::TIMESTAMPTZ AS manual_created_at
        FROM trip_data td
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao ON tao.day_approval_id = da.id
            AND tao.activity_type = 'trip' AND tao.activity_id = td.activity_id

        UNION ALL

        -- Trip segments
        SELECT
            tsd.activity_type, tsd.activity_id, tsd.shift_id,
            tsd.started_at, tsd.ended_at, tsd.duration_minutes,
            tsd.matched_location_id, tsd.location_name, tsd.location_type,
            tsd.latitude, tsd.longitude, tsd.gps_gap_seconds, tsd.gps_gap_count,
            tsd.auto_status, tsd.auto_reason,
            tsd.override_status, tsd.override_reason, tsd.final_status,
            tsd.distance_km, tsd.road_distance_km, tsd.transport_mode, tsd.has_gps_gap,
            tsd.start_location_id, tsd.start_location_name, tsd.start_location_type,
            tsd.end_location_id, tsd.end_location_name, tsd.end_location_type,
            tsd.shift_type, tsd.shift_type_source,
            tsd.is_edited, tsd.original_value,
            NULL::JSONB AS children,
            NULL::TEXT AS manual_reason,
            NULL::BOOLEAN AS is_standalone_shift,
            NULL::TEXT AS manual_created_by,
            NULL::TIMESTAMPTZ AS manual_created_at
        FROM trip_segment_data tsd

        UNION ALL

        -- Clock events
        SELECT
            cd.activity_type, cd.activity_id, cd.shift_id,
            cd.started_at, cd.ended_at, cd.duration_minutes,
            cd.matched_location_id, cd.location_name, cd.location_type,
            cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
            cd.auto_status, cd.auto_reason,
            cao.override_status, cao.reason AS override_reason,
            COALESCE(cao.override_status, cd.auto_status) AS final_status,
            cd.distance_km, cd.road_distance_km, cd.transport_mode, cd.has_gps_gap,
            cd.start_location_id, cd.start_location_name, cd.start_location_type,
            cd.end_location_id, cd.end_location_name, cd.end_location_type,
            cd.shift_type, cd.shift_type_source,
            cd.is_edited, cd.original_value,
            NULL::JSONB AS children,
            NULL::TEXT AS manual_reason,
            NULL::BOOLEAN AS is_standalone_shift,
            NULL::TEXT AS manual_created_by,
            NULL::TIMESTAMPTZ AS manual_created_at
        FROM clock_data cd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao ON cao.day_approval_id = da.id
            AND cao.activity_type = cd.activity_type AND cao.activity_id = cd.activity_id

        UNION ALL

        -- Lunch
        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.road_distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source,
            ld.is_edited, ld.original_value,
            ld.children,
            NULL::TEXT AS manual_reason,
            NULL::BOOLEAN AS is_standalone_shift,
            NULL::TEXT AS manual_created_by,
            NULL::TIMESTAMPTZ AS manual_created_at
        FROM lunch_data ld

        UNION ALL

        -- Manual time entries
        SELECT
            mtd.activity_type, mtd.activity_id, mtd.shift_id,
            mtd.started_at, mtd.ended_at, mtd.duration_minutes,
            mtd.matched_location_id, mtd.location_name, mtd.location_type,
            mtd.latitude, mtd.longitude, mtd.gps_gap_seconds, mtd.gps_gap_count,
            mtd.auto_status, mtd.auto_reason,
            mtd.override_status, mtd.override_reason, mtd.final_status,
            mtd.distance_km, mtd.road_distance_km, mtd.transport_mode, mtd.has_gps_gap,
            mtd.start_location_id, mtd.start_location_name, mtd.start_location_type,
            mtd.end_location_id, mtd.end_location_name, mtd.end_location_type,
            mtd.shift_type, mtd.shift_type_source,
            mtd.is_edited, mtd.original_value,
            NULL::JSONB AS children,
            mtd.manual_reason,
            mtd.is_standalone_shift,
            mtd.manual_created_by_name AS manual_created_by,
            mtd.manual_created_at
        FROM manual_time_data mtd

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
            'road_distance_km', c.road_distance_km,
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
            'shift_type_source', c.shift_type_source,
            'is_edited', c.is_edited,
            'original_value', c.original_value,
            'children', c.children,
            'manual_reason', c.manual_reason,
            'is_standalone_shift', c.is_standalone_shift,
            'manual_created_by', c.manual_created_by,
            'manual_created_at', c.manual_created_at
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- =====================================================================
    -- Gap detection: find >5min periods within completed shifts with no activity
    -- Excludes lunch segments from shift_boundaries
    -- =====================================================================
    WITH shift_boundaries AS (
        SELECT
            s.id AS shift_id,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND est.effective_clocked_out_at IS NOT NULL
          AND NOT s.is_lunch
    ),
    activity_evts AS (
        -- Stops (1-min tolerance)
        SELECT
            sb.shift_id,
            GREATEST(sc.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(sc.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN stationary_clusters sc
            ON sc.employee_id = p_employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at
           AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180

        UNION ALL

        -- Trips (1-min tolerance)
        SELECT
            sb.shift_id,
            GREATEST(t.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(t.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN trips t
            ON t.employee_id = p_employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at
           AND t.ended_at > sb.clocked_in_at

        UNION ALL

        -- Lunch segments as coverage events (via work_body_id)
        SELECT
            sb.shift_id,
            GREATEST(s_lunch.clocked_in_at, sb.clocked_in_at) AS evt_start,
            LEAST(s_lunch.clocked_out_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN shifts s_lunch ON s_lunch.employee_id = p_employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL

        UNION ALL

        -- Manual time entries as coverage events (exclude gaps that overlap with manual time)
        SELECT
            sb.shift_id,
            GREATEST(mte.starts_at, sb.clocked_in_at) AS evt_start,
            LEAST(mte.ends_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN manual_time_entries mte
            ON mte.employee_id = p_employee_id
           AND mte.date = p_date
           AND mte.starts_at < sb.clocked_out_at
           AND mte.ends_at > sb.clocked_in_at
    ),
    coverage_sorted AS (
        SELECT shift_id, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_evts
    ),
    coverage_with_max AS (
        SELECT cs.*,
               MAX(evt_end) OVER (PARTITION BY shift_id ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
        FROM coverage_sorted cs
    ),
    coverage_islands AS (
        SELECT shift_id, evt_start, evt_end,
               SUM(CASE WHEN rn = 1 OR evt_start > prev_max_end THEN 1 ELSE 0 END)
                   OVER (PARTITION BY shift_id ORDER BY rn) AS island_id
        FROM coverage_with_max
    ),
    coverage_spans AS (
        SELECT shift_id, island_id, MIN(evt_start) AS span_start, MAX(evt_end) AS span_end
        FROM coverage_islands
        GROUP BY shift_id, island_id
    ),
    spans_numbered AS (
        SELECT shift_id, span_start, span_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY span_start) AS span_rn,
               COUNT(*) OVER (PARTITION BY shift_id) AS span_count
        FROM coverage_spans
    ),
    gap_candidates AS (
        -- Gap before first activity
        SELECT sb.shift_id, sb.clocked_in_at AS gap_start, sn.span_start AS gap_end
        FROM shift_boundaries sb
        JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = 1

        UNION ALL

        -- Gaps between spans
        SELECT sn1.shift_id, sn1.span_end AS gap_start, sn2.span_start AS gap_end
        FROM spans_numbered sn1
        JOIN spans_numbered sn2 ON sn2.shift_id = sn1.shift_id AND sn2.span_rn = sn1.span_rn + 1

        UNION ALL

        -- Gap after last activity
        SELECT sb.shift_id, sn.span_end AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb
        JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = sn.span_count

        UNION ALL

        -- Shifts with NO activities
        SELECT sb.shift_id, sb.clocked_in_at AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb
        WHERE NOT EXISTS (SELECT 1 FROM activity_evts ae WHERE ae.shift_id = sb.shift_id)
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', 'gap',
            'activity_id', md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID,
            'shift_id', gc.shift_id,
            'started_at', gc.gap_start,
            'ended_at', gc.gap_end,
            'duration_minutes', (EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)) / 60)::INTEGER,
            'auto_status', 'needs_review',
            'auto_reason', 'Temps non suivi',
            'override_status', COALESCE(ao.override_status, NULL),
            'override_reason', COALESCE(ao.reason, NULL),
            'final_status', COALESCE(ao.override_status, 'needs_review'),
            'matched_location_id', NULL,
            'location_name', NULL,
            'location_type', NULL,
            'latitude', NULL,
            'longitude', NULL,
            'distance_km', NULL,
            'road_distance_km', NULL,
            'transport_mode', NULL,
            'has_gps_gap', TRUE,
            'start_location_id', NULL,
            'start_location_name', NULL,
            'start_location_type', NULL,
            'end_location_id', NULL,
            'end_location_name', NULL,
            'end_location_type', NULL,
            'gps_gap_seconds', (EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)))::INTEGER,
            'gps_gap_count', 1,
            'shift_type', NULL,
            'shift_type_source', NULL,
            'is_edited', FALSE,
            'original_value', NULL,
            'children', NULL,
            'manual_reason', NULL,
            'is_standalone_shift', NULL,
            'manual_created_by', NULL,
            'manual_created_at', NULL
        )
    )
    INTO v_gaps
    FROM gap_candidates gc
    LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'gap'
        AND ao.activity_id = md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID
    WHERE EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)) > 300
      -- Exclude segmented parent gaps
      AND md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID
          NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'gap');

    -- Merge gaps into activities and re-sort
    IF v_gaps IS NOT NULL THEN
        SELECT jsonb_agg(elem ORDER BY elem->>'started_at' ASC)
        INTO v_activities
        FROM (
            SELECT jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) AS elem
            UNION ALL
            SELECT jsonb_array_elements(v_gaps) AS elem
        ) combined;
    END IF;

    -- =====================================================================
    -- Gap segments: segments of gaps that have been split
    -- =====================================================================
    WITH gap_seg_data AS (
        SELECT
            'gap_segment'::TEXT AS activity_type,
            aseg.id AS activity_id,
            (SELECT s.id FROM shifts s WHERE s.employee_id = p_employee_id
                AND s.clocked_in_at <= aseg.starts_at
                AND COALESCE(s.clocked_out_at, now()) >= aseg.ends_at
                AND NOT s.is_lunch LIMIT 1) AS shift_id,
            aseg.starts_at,
            aseg.ends_at,
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
            'needs_review'::TEXT AS auto_status,
            'Temps non suivi (segment)'::TEXT AS auto_reason,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, 'needs_review') AS final_status
        FROM activity_segments aseg
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'gap_segment' AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'gap'
          AND aseg.employee_id = p_employee_id
          AND aseg.starts_at >= p_date::TIMESTAMPTZ
          AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', gsd.activity_type,
            'activity_id', gsd.activity_id,
            'shift_id', gsd.shift_id,
            'started_at', gsd.starts_at,
            'ended_at', gsd.ends_at,
            'duration_minutes', gsd.duration_minutes,
            'auto_status', gsd.auto_status,
            'auto_reason', gsd.auto_reason,
            'override_status', gsd.override_status,
            'override_reason', gsd.override_reason,
            'final_status', gsd.final_status,
            'matched_location_id', NULL,
            'location_name', NULL,
            'location_type', NULL,
            'latitude', NULL,
            'longitude', NULL,
            'distance_km', NULL,
            'road_distance_km', NULL,
            'transport_mode', NULL,
            'has_gps_gap', TRUE,
            'start_location_id', NULL,
            'start_location_name', NULL,
            'start_location_type', NULL,
            'end_location_id', NULL,
            'end_location_name', NULL,
            'end_location_type', NULL,
            'gps_gap_seconds', EXTRACT(EPOCH FROM (gsd.ends_at - gsd.starts_at))::INTEGER,
            'gps_gap_count', 1,
            'shift_type', NULL,
            'shift_type_source', NULL,
            'is_edited', FALSE,
            'original_value', NULL,
            'children', NULL,
            'manual_reason', NULL,
            'is_standalone_shift', NULL,
            'manual_created_by', NULL,
            'manual_created_at', NULL
        )
    )
    INTO v_gap_segments
    FROM gap_seg_data gsd;

    -- Merge gap segments into activities
    IF v_gap_segments IS NOT NULL THEN
        SELECT jsonb_agg(elem ORDER BY elem->>'started_at' ASC)
        INTO v_activities
        FROM (
            SELECT jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) AS elem
            UNION ALL
            SELECT jsonb_array_elements(v_gap_segments) AS elem
        ) combined;
    END IF;

    -- Compute summary -- needs_review_count includes stop_segment, trip_segment, gap_segment
    -- Always exclude clock_in/clock_out/lunch: they are 0-duration metadata and must never block approval.
    -- Previously used a 60s overlap heuristic that failed for micro-shifts (< 30s) whose clock events
    -- fall outside any stop's time range.
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' NOT IN ('lunch', 'gap', 'gap_segment')), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected' AND a->>'activity_type' NOT IN ('gap', 'gap_segment', 'lunch')), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND a->>'activity_type' NOT IN ('clock_in', 'clock_out', 'lunch')
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen totals
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    -- Cap approved minutes at shift duration (activities can extend beyond shift boundaries)
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);

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
$function$;


-- =====================================================================
-- 2) UPDATE save_activity_override to accept 'manual_time'
-- =====================================================================
CREATE OR REPLACE FUNCTION public.save_activity_override(p_employee_id uuid, p_date date, p_activity_type text, p_activity_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_caller UUID := auth.uid();
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth check
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Validate override status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Override status must be approved or rejected';
    END IF;

    -- Validate activity type (now includes stop_segment, trip_segment, gap_segment, manual_time)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment', 'trip_segment', 'gap_segment', 'lunch_segment', 'manual_time') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Get or create day_approval
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING;

    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- Cannot override on approved days
    IF (SELECT status FROM day_approvals WHERE id = v_day_approval_id) = 'approved' THEN
        RAISE EXCEPTION 'Cannot modify overrides on an approved day';
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated day detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$function$;


-- =====================================================================
-- 3) UPDATE remove_activity_override to accept 'manual_time'
-- =====================================================================
CREATE OR REPLACE FUNCTION public.remove_activity_override(p_employee_id uuid, p_date date, p_activity_type text, p_activity_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    -- Validate activity type (matches save_activity_override accepted types)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment', 'trip_segment', 'gap_segment', 'lunch_segment', 'manual_time') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id
      AND da.date = p_date
      AND ao.activity_type = p_activity_type
      AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$function$;
