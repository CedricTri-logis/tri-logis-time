-- Fix: Remove detect_carpools call from prefill_mileage_defaults
-- detect_carpools is O(n²) per day and causes timeouts when called for 14 days.
-- Carpools should already be detected during trip detection.
-- The prefill just reads existing carpool_members data.

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
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can prefill mileage defaults';
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

    -- Check carpool membership (reads existing data, does not re-detect)
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
