-- Migration 068: Update get_mileage_summary for carpooling and company vehicles
-- Reimbursable = business + driving + NOT company_vehicle + (driver OR solo)

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
                 AND NOT has_active_vehicle_period(t.employee_id, 'company', t.started_at::DATE)
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
                 AND NOT has_active_vehicle_period(t.employee_id, 'company', t.started_at::DATE)
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
      AND t.started_at >= p_period_start::TIMESTAMPTZ
      AND t.started_at < (p_period_end + 1)::TIMESTAMPTZ;

    -- Calculate YTD business km
    SELECT COALESCE(SUM(CASE
        WHEN t.classification = 'business'
             AND t.transport_mode = 'driving'
             AND NOT has_active_vehicle_period(t.employee_id, 'company', t.started_at::DATE)
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
      AND t.started_at >= (v_period_year || '-01-01')::TIMESTAMPTZ
      AND t.started_at < (p_period_end + 1)::TIMESTAMPTZ;

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

COMMENT ON FUNCTION get_mileage_summary IS 'Mileage summary with tiered CRA reimbursement. Excludes carpool passengers and company vehicle trips from reimbursable km.';
