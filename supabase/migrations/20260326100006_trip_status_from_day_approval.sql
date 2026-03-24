-- Fix: Get trip status from day approval system (auto_status + override)
-- Uses COALESCE(override_status, auto_status) matching get_day_approval_detail logic.
-- Also includes location name fallback and adjacent cluster lookup.

CREATE OR REPLACE FUNCTION get_mileage_approval_detail(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_trips JSONB;
  v_summary JSONB;
  v_approval JSONB;
  v_reimbursable_km DECIMAL;
  v_company_km DECIMAL;
  v_passenger_km DECIMAL;
  v_needs_review INTEGER;
  v_estimated_amount DECIMAL;
  v_ytd_km DECIMAL;
  v_rate_per_km DECIMAL;
  v_threshold_km DECIMAL;
  v_rate_after DECIMAL;
  v_forfait_amount DECIMAL;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can view mileage approval detail';
  END IF;

  SELECT jsonb_agg(trip_row ORDER BY trip_date, started_at)
  INTO v_trips
  FROM (
    SELECT
      to_business_date(t.started_at) AS trip_date,
      t.id AS trip_id,
      t.started_at,
      t.ended_at,
      COALESCE(t.start_address, sl.name) AS start_address,
      COALESCE(t.end_address, el.name) AS end_address,
      t.start_location_id,
      t.end_location_id,
      sl.location_type AS start_location_type,
      el.location_type AS end_location_type,
      COALESCE(t.road_distance_km, t.distance_km) AS distance_km,
      t.vehicle_type,
      t.role,
      t.transport_mode,
      t.has_gps_gap,
      cm.carpool_group_id,
      cm.role AS carpool_detected_role,
      (
        SELECT jsonb_agg(jsonb_build_object(
          'employee_id', cm2.employee_id,
          'employee_name', ep2.full_name,
          'role', cm2.role,
          'trip_id', cm2.trip_id
        ))
        FROM carpool_members cm2
        JOIN employee_profiles ep2 ON ep2.id = cm2.employee_id
        WHERE cm2.carpool_group_id = cm.carpool_group_id
          AND cm2.employee_id != p_employee_id
      ) AS carpool_members,
      COALESCE(
        ao.override_status,
        CASE
          WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
           AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
          WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
            OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
          ELSE 'needs_review'
        END
      ) AS trip_status
    FROM trips t
    LEFT JOIN carpool_members cm ON cm.trip_id = t.id
    LEFT JOIN locations sl ON sl.id = t.start_location_id
    LEFT JOIN locations el ON el.id = t.end_location_id
    LEFT JOIN LATERAL (
      SELECT sc2.matched_location_id
      FROM stationary_clusters sc2
      WHERE sc2.employee_id = p_employee_id AND sc2.ended_at = t.started_at
      LIMIT 1
    ) dep_cluster ON t.start_location_id IS NULL
    LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
    LEFT JOIN LATERAL (
      SELECT sc3.matched_location_id
      FROM stationary_clusters sc3
      WHERE sc3.employee_id = p_employee_id AND sc3.started_at = t.ended_at
      LIMIT 1
    ) arr_cluster ON t.end_location_id IS NULL
    LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
    LEFT JOIN day_approvals da
      ON da.employee_id = p_employee_id AND da.date = to_business_date(t.started_at)
    LEFT JOIN activity_overrides ao
      ON ao.day_approval_id = da.id AND ao.activity_type = 'trip' AND ao.activity_id = t.id
    WHERE t.employee_id = p_employee_id
      AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
  ) trip_row;

  SELECT
    COALESCE(SUM(CASE WHEN t.vehicle_type = 'personal' AND t.role = 'driver'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN t.vehicle_type = 'company'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN t.role = 'passenger'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COUNT(CASE WHEN t.vehicle_type IS NULL OR t.role IS NULL THEN 1 END)
  INTO v_reimbursable_km, v_company_km, v_passenger_km, v_needs_review
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving';

  SELECT rr.rate_per_km, rr.threshold_km, rr.rate_after_threshold
  INTO v_rate_per_km, v_threshold_km, v_rate_after
  FROM reimbursement_rates rr
  WHERE rr.effective_from <= p_period_end
  ORDER BY rr.effective_from DESC
  LIMIT 1;

  SELECT COALESCE(SUM(COALESCE(t.road_distance_km, t.distance_km)), 0)
  INTO v_ytd_km
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) >= date_trunc('year', p_period_end::TIMESTAMP)::DATE
    AND to_business_date(t.started_at) < p_period_start
    AND t.transport_mode = 'driving'
    AND t.vehicle_type = 'personal'
    AND t.role = 'driver';

  IF v_threshold_km IS NOT NULL AND v_rate_after IS NOT NULL THEN
    IF v_ytd_km >= v_threshold_km THEN
      v_estimated_amount := v_reimbursable_km * v_rate_after;
    ELSIF (v_ytd_km + v_reimbursable_km) <= v_threshold_km THEN
      v_estimated_amount := v_reimbursable_km * v_rate_per_km;
    ELSE
      v_estimated_amount :=
        (v_threshold_km - v_ytd_km) * v_rate_per_km +
        (v_reimbursable_km - (v_threshold_km - v_ytd_km)) * v_rate_after;
    END IF;
  ELSE
    v_estimated_amount := v_reimbursable_km * v_rate_per_km;
  END IF;

  -- Check for fixed mileage allowance (forfait)
  v_forfait_amount := get_active_mileage_allowance(p_employee_id, p_period_start);
  IF v_forfait_amount IS NOT NULL THEN
    v_estimated_amount := v_forfait_amount;
  END IF;

  v_summary := jsonb_build_object(
    'reimbursable_km', ROUND(v_reimbursable_km, 2),
    'company_km', ROUND(v_company_km, 2),
    'passenger_km', ROUND(v_passenger_km, 2),
    'needs_review_count', v_needs_review,
    'estimated_amount', ROUND(v_estimated_amount, 2),
    'ytd_km', ROUND(v_ytd_km, 2),
    'rate_per_km', v_rate_per_km,
    'rate_after_threshold', v_rate_after,
    'threshold_km', v_threshold_km,
    'is_forfait', v_forfait_amount IS NOT NULL,
    'forfait_amount', v_forfait_amount
  );

  SELECT to_jsonb(ma)
  INTO v_approval
  FROM mileage_approvals ma
  WHERE ma.employee_id = p_employee_id
    AND ma.period_start = p_period_start
    AND ma.period_end = p_period_end;

  RETURN jsonb_build_object(
    'trips', COALESCE(v_trips, '[]'::JSONB),
    'summary', v_summary,
    'approval', v_approval
  );
END;
$$;
