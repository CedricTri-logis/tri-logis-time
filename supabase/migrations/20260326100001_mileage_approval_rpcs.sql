-- =============================================================
-- Mileage Approval RPCs
-- =============================================================

-- prefill_mileage_defaults: Auto-assign vehicle_type and role on unassigned trips
CREATE OR REPLACE FUNCTION prefill_mileage_defaults(
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
  v_trip RECORD;
  v_prefilled INTEGER := 0;
  v_needs_review INTEGER := 0;
  v_has_personal BOOLEAN;
  v_has_company BOOLEAN;
  v_carpool_role TEXT;
  v_default_vehicle TEXT;
  v_default_role TEXT;
  v_trip_date DATE;
  v_dates_in_period DATE[];
  v_d DATE;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can prefill mileage defaults';
  END IF;

  -- Run detect_carpools for each day in the period that has trips
  SELECT ARRAY_AGG(DISTINCT to_business_date(t.started_at))
  INTO v_dates_in_period
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving';

  IF v_dates_in_period IS NOT NULL THEN
    FOREACH v_d IN ARRAY v_dates_in_period LOOP
      PERFORM detect_carpools(v_d);
    END LOOP;
  END IF;

  -- Iterate over unassigned driving trips
  FOR v_trip IN
    SELECT t.id, t.started_at, t.employee_id
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
      AND (t.vehicle_type IS NULL OR t.role IS NULL)
  LOOP
    v_trip_date := to_business_date(v_trip.started_at);
    v_default_vehicle := NULL;
    v_default_role := NULL;

    -- Check vehicle periods
    v_has_personal := has_active_vehicle_period(v_trip.employee_id, 'personal', v_trip_date);
    v_has_company := has_active_vehicle_period(v_trip.employee_id, 'company', v_trip_date);

    IF v_has_personal AND NOT v_has_company THEN
      v_default_vehicle := 'personal';
    ELSIF v_has_company AND NOT v_has_personal THEN
      v_default_vehicle := 'company';
    END IF;

    -- Check carpool membership
    SELECT cm.role INTO v_carpool_role
    FROM carpool_members cm
    WHERE cm.trip_id = v_trip.id;

    IF v_carpool_role IS NOT NULL AND v_carpool_role != 'unassigned' THEN
      v_default_role := v_carpool_role;
    ELSIF v_carpool_role IS NULL THEN
      v_default_role := 'driver';
    END IF;

    -- Update trip
    UPDATE trips
    SET vehicle_type = COALESCE(trips.vehicle_type, v_default_vehicle),
        role = COALESCE(trips.role, v_default_role)
    WHERE id = v_trip.id;

    IF v_default_vehicle IS NOT NULL AND v_default_role IS NOT NULL THEN
      v_prefilled := v_prefilled + 1;
    ELSE
      v_needs_review := v_needs_review + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'prefilled_count', v_prefilled,
    'needs_review_count', v_needs_review
  );
END;
$$;

CREATE OR REPLACE FUNCTION update_trip_vehicle(
  p_trip_id UUID,
  p_vehicle_type TEXT,
  p_role TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_trip RECORD;
  v_trip_date DATE;
  v_carpool_group_id UUID;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can update trip vehicle';
  END IF;

  IF p_vehicle_type IS NOT NULL AND p_vehicle_type NOT IN ('personal', 'company') THEN
    RAISE EXCEPTION 'Invalid vehicle_type: %. Must be personal or company', p_vehicle_type;
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('driver', 'passenger') THEN
    RAISE EXCEPTION 'Invalid role: %. Must be driver or passenger', p_role;
  END IF;

  SELECT * INTO v_trip FROM trips WHERE id = p_trip_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip not found: %', p_trip_id;
  END IF;

  v_trip_date := to_business_date(v_trip.started_at);
  IF EXISTS (
    SELECT 1 FROM mileage_approvals
    WHERE employee_id = v_trip.employee_id
      AND status = 'approved'
      AND period_start <= v_trip_date
      AND period_end >= v_trip_date
  ) THEN
    RAISE EXCEPTION 'Mileage is locked for this period. Reopen mileage approval first.';
  END IF;

  UPDATE trips
  SET vehicle_type = COALESCE(p_vehicle_type, trips.vehicle_type),
      role = COALESCE(p_role, trips.role)
  WHERE id = p_trip_id;

  IF p_role = 'driver' THEN
    SELECT cm.carpool_group_id INTO v_carpool_group_id
    FROM carpool_members cm
    WHERE cm.trip_id = p_trip_id;

    IF v_carpool_group_id IS NOT NULL THEN
      UPDATE trips t
      SET role = 'passenger'
      FROM carpool_members cm
      WHERE cm.trip_id = t.id
        AND cm.carpool_group_id = v_carpool_group_id
        AND t.id != p_trip_id;

      UPDATE carpool_members
      SET role = 'driver'
      WHERE trip_id = p_trip_id;

      UPDATE carpool_members cm
      SET role = 'passenger'
      WHERE cm.carpool_group_id = v_carpool_group_id
        AND cm.trip_id != p_trip_id;
    END IF;
  END IF;

  IF p_role IS NOT NULL AND v_carpool_group_id IS NULL THEN
    UPDATE carpool_members
    SET role = p_role
    WHERE trip_id = p_trip_id;
  END IF;

  RETURN to_jsonb((SELECT t FROM trips t WHERE t.id = p_trip_id));
END;
$$;

CREATE OR REPLACE FUNCTION batch_update_trip_vehicles(
  p_trip_ids UUID[],
  p_vehicle_type TEXT,
  p_role TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_trip_id UUID;
  v_updated INTEGER := 0;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can batch update trip vehicles';
  END IF;

  FOREACH v_trip_id IN ARRAY p_trip_ids LOOP
    PERFORM update_trip_vehicle(v_trip_id, p_vehicle_type, p_role);
    v_updated := v_updated + 1;
  END LOOP;

  RETURN jsonb_build_object('updated_count', v_updated);
END;
$$;

CREATE OR REPLACE FUNCTION get_mileage_approval_summary(
  p_period_start DATE,
  p_period_end DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_result JSONB;
  v_rate_per_km DECIMAL;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can view mileage approval summary';
  END IF;

  SELECT rr.rate_per_km INTO v_rate_per_km
  FROM reimbursement_rates rr
  WHERE rr.effective_from <= p_period_end
  ORDER BY rr.effective_from DESC LIMIT 1;

  WITH trip_data AS (
    SELECT
      t.id AS trip_id,
      t.employee_id,
      COALESCE(t.road_distance_km, t.distance_km) AS distance,
      t.vehicle_type,
      t.role
    FROM trips t
    WHERE to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
  ),
  carpool_counts AS (
    SELECT td.employee_id, COUNT(DISTINCT cm.carpool_group_id) AS carpool_group_count
    FROM trip_data td
    JOIN carpool_members cm ON cm.trip_id = td.trip_id
    GROUP BY td.employee_id
  )
  SELECT jsonb_agg(row_data ORDER BY needs_review_count DESC, employee_name)
  INTO v_result
  FROM (
    SELECT
      ep.id AS employee_id,
      ep.full_name AS employee_name,
      COUNT(td.trip_id) AS trip_count,
      COALESCE(SUM(
        CASE WHEN td.vehicle_type = 'personal' AND td.role = 'driver'
        THEN td.distance ELSE 0 END
      ), 0) AS reimbursable_km,
      COALESCE(SUM(
        CASE WHEN td.vehicle_type = 'company'
        THEN td.distance ELSE 0 END
      ), 0) AS company_km,
      COUNT(CASE WHEN td.vehicle_type IS NULL OR td.role IS NULL THEN 1 END) AS needs_review_count,
      COALESCE(cc.carpool_group_count, 0) AS carpool_group_count,
      ROUND(COALESCE(SUM(
        CASE WHEN td.vehicle_type = 'personal' AND td.role = 'driver'
        THEN td.distance ELSE 0 END
      ), 0) * COALESCE(v_rate_per_km, 0), 2) AS estimated_amount,
      ma.status AS mileage_status,
      ma.reimbursable_km AS approved_km,
      ma.reimbursement_amount AS approved_amount
    FROM trip_data td
    JOIN employee_profiles ep ON ep.id = td.employee_id
    LEFT JOIN carpool_counts cc ON cc.employee_id = td.employee_id
    LEFT JOIN mileage_approvals ma
      ON ma.employee_id = td.employee_id
      AND ma.period_start = p_period_start
      AND ma.period_end = p_period_end
    GROUP BY ep.id, ep.full_name, cc.carpool_group_count, ma.status, ma.reimbursable_km, ma.reimbursement_amount
  ) row_data;

  RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$;

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
      t.start_address,
      t.end_address,
      t.start_location_id,
      t.end_location_id,
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
      CASE
        WHEN t.transport_mode != 'driving' THEN FALSE
        ELSE TRUE
      END AS eligible
    FROM trips t
    LEFT JOIN carpool_members cm ON cm.trip_id = t.id
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

  v_summary := jsonb_build_object(
    'reimbursable_km', ROUND(v_reimbursable_km, 2),
    'company_km', ROUND(v_company_km, 2),
    'passenger_km', ROUND(v_passenger_km, 2),
    'needs_review_count', v_needs_review,
    'estimated_amount', ROUND(v_estimated_amount, 2),
    'ytd_km', ROUND(v_ytd_km, 2),
    'rate_per_km', v_rate_per_km,
    'rate_after_threshold', v_rate_after,
    'threshold_km', v_threshold_km
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

CREATE OR REPLACE FUNCTION approve_mileage(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_needs_review INTEGER;
  v_unapproved_days INTEGER;
  v_detail JSONB;
  v_result mileage_approvals;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can approve mileage';
  END IF;

  SELECT COUNT(*) INTO v_unapproved_days
  FROM day_approvals da
  WHERE da.employee_id = p_employee_id
    AND da.date BETWEEN p_period_start AND p_period_end
    AND da.status != 'approved';

  IF v_unapproved_days > 0 THEN
    RAISE EXCEPTION '% day(s) not yet approved for this period', v_unapproved_days;
  END IF;

  SELECT COUNT(*) INTO v_needs_review
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving'
    AND (t.vehicle_type IS NULL OR t.role IS NULL);

  IF v_needs_review > 0 THEN
    RAISE EXCEPTION '% trip(s) still need vehicle/role assignment', v_needs_review;
  END IF;

  v_detail := get_mileage_approval_detail(p_employee_id, p_period_start, p_period_end);

  INSERT INTO mileage_approvals (
    employee_id, period_start, period_end, status,
    reimbursable_km, reimbursement_amount,
    approved_by, approved_at, notes
  )
  VALUES (
    p_employee_id, p_period_start, p_period_end, 'approved',
    (v_detail->'summary'->>'reimbursable_km')::DECIMAL,
    (v_detail->'summary'->>'estimated_amount')::DECIMAL,
    v_caller, now(), p_notes
  )
  ON CONFLICT (employee_id, period_start, period_end)
  DO UPDATE SET
    status = 'approved',
    reimbursable_km = EXCLUDED.reimbursable_km,
    reimbursement_amount = EXCLUDED.reimbursement_amount,
    approved_by = EXCLUDED.approved_by,
    approved_at = EXCLUDED.approved_at,
    notes = EXCLUDED.notes,
    updated_at = now()
  RETURNING * INTO v_result;

  RETURN to_jsonb(v_result);
END;
$$;

CREATE OR REPLACE FUNCTION reopen_mileage_approval(
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
  v_result mileage_approvals;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can reopen mileage approval';
  END IF;

  UPDATE mileage_approvals
  SET status = 'pending',
      unlocked_by = v_caller,
      unlocked_at = now(),
      approved_by = NULL,
      approved_at = NULL,
      updated_at = now()
  WHERE employee_id = p_employee_id
    AND period_start = p_period_start
    AND period_end = p_period_end
    AND status = 'approved'
  RETURNING * INTO v_result;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No approved mileage found for this employee and period';
  END IF;

  RETURN to_jsonb(v_result);
END;
$$;
