-- =============================================================================
-- 032: Mileage Tracking - Trips & Trip GPS Points
-- Feature: 017-mileage-tracking
-- =============================================================================

-- trips: Detected vehicle trips derived from GPS points during shifts
CREATE TABLE trips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,

    -- Trip boundaries
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,

    -- Start location
    start_latitude DECIMAL(10, 8) NOT NULL,
    start_longitude DECIMAL(11, 8) NOT NULL,
    start_address TEXT,
    start_location_id UUID REFERENCES locations(id),

    -- End location
    end_latitude DECIMAL(10, 8) NOT NULL,
    end_longitude DECIMAL(11, 8) NOT NULL,
    end_address TEXT,
    end_location_id UUID REFERENCES locations(id),

    -- Distance and duration
    distance_km DECIMAL(8, 3) NOT NULL,
    duration_minutes INTEGER NOT NULL,

    -- Classification
    classification TEXT NOT NULL DEFAULT 'business'
        CHECK (classification IN ('business', 'personal')),

    -- Quality indicators
    confidence_score DECIMAL(3, 2) NOT NULL DEFAULT 1.0
        CHECK (confidence_score >= 0 AND confidence_score <= 1),
    gps_point_count INTEGER NOT NULL DEFAULT 0,
    low_accuracy_segments INTEGER NOT NULL DEFAULT 0,

    -- Metadata
    detection_method TEXT NOT NULL DEFAULT 'auto'
        CHECK (detection_method IN ('auto', 'manual')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT trip_times_valid CHECK (ended_at > started_at),
    CONSTRAINT trip_distance_positive CHECK (distance_km >= 0)
);

COMMENT ON TABLE trips IS 'Detected vehicle trips from GPS points during shifts (017-mileage-tracking)';

-- Indexes
CREATE INDEX idx_trips_shift_id ON trips(shift_id);
CREATE INDEX idx_trips_employee_id ON trips(employee_id);
CREATE INDEX idx_trips_started_at ON trips(started_at DESC);
CREATE INDEX idx_trips_classification ON trips(classification);
CREATE INDEX idx_trips_employee_period ON trips(employee_id, started_at DESC);

-- trip_gps_points: Junction table linking trips to contributing GPS points
CREATE TABLE trip_gps_points (
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    gps_point_id UUID NOT NULL REFERENCES gps_points(id) ON DELETE CASCADE,
    sequence_order INTEGER NOT NULL,
    PRIMARY KEY (trip_id, gps_point_id)
);

CREATE INDEX idx_trip_gps_points_trip ON trip_gps_points(trip_id);

-- Updated_at trigger
CREATE OR REPLACE FUNCTION update_trips_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trips_updated_at
    BEFORE UPDATE ON trips
    FOR EACH ROW
    EXECUTE FUNCTION update_trips_updated_at();

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE trips ENABLE ROW LEVEL SECURITY;

-- Employees can view their own trips
CREATE POLICY "Employees can view own trips"
ON trips FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

-- Managers can view trips of supervised employees
CREATE POLICY "Managers can view supervised employee trips"
ON trips FOR SELECT TO authenticated
USING (
    employee_id IN (
        SELECT es.employee_id FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- Employees can update their own trip classification only
CREATE POLICY "Employees can update own trip classification"
ON trips FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = employee_id)
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- System inserts trips via RPC (SECURITY DEFINER), but allow authenticated insert for the RPC
CREATE POLICY "System can insert trips"
ON trips FOR INSERT TO authenticated
WITH CHECK (true);

-- System can delete trips for re-detection (via RPC)
CREATE POLICY "System can delete trips"
ON trips FOR DELETE TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR employee_id IN (
        SELECT es.employee_id FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- trip_gps_points RLS
ALTER TABLE trip_gps_points ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view trip GPS points for accessible trips"
ON trip_gps_points FOR SELECT TO authenticated
USING (
    trip_id IN (SELECT id FROM trips)
);

CREATE POLICY "System can insert trip GPS points"
ON trip_gps_points FOR INSERT TO authenticated
WITH CHECK (true);

CREATE POLICY "System can delete trip GPS points"
ON trip_gps_points FOR DELETE TO authenticated
USING (
    trip_id IN (SELECT id FROM trips)
);
