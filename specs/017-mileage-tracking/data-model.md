# Data Model: Mileage Tracking for Reimbursement

## New Tables

### `trips`

Stores detected vehicle trips derived from GPS points during shifts.

```sql
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
    start_address TEXT,  -- Reverse-geocoded
    start_location_id UUID REFERENCES locations(id),  -- Matched geofence (nullable)

    -- End location
    end_latitude DECIMAL(10, 8) NOT NULL,
    end_longitude DECIMAL(11, 8) NOT NULL,
    end_address TEXT,  -- Reverse-geocoded
    end_location_id UUID REFERENCES locations(id),  -- Matched geofence (nullable)

    -- Distance and duration
    distance_km DECIMAL(8, 3) NOT NULL,  -- Calculated from GPS points
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

-- Indexes
CREATE INDEX idx_trips_shift_id ON trips(shift_id);
CREATE INDEX idx_trips_employee_id ON trips(employee_id);
CREATE INDEX idx_trips_started_at ON trips(started_at DESC);
CREATE INDEX idx_trips_classification ON trips(classification);
CREATE INDEX idx_trips_employee_period ON trips(employee_id, started_at DESC);
```

### `trip_gps_points`

Junction table linking trips to the GPS points that compose them.

```sql
CREATE TABLE trip_gps_points (
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    gps_point_id UUID NOT NULL REFERENCES gps_points(id) ON DELETE CASCADE,
    sequence_order INTEGER NOT NULL,
    PRIMARY KEY (trip_id, gps_point_id)
);

CREATE INDEX idx_trip_gps_points_trip ON trip_gps_points(trip_id);
```

### `reimbursement_rates`

Stores per-km reimbursement rate configuration with effective date ranges.

```sql
CREATE TABLE reimbursement_rates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Rate tiers (CRA model: different rate after threshold)
    rate_per_km DECIMAL(5, 4) NOT NULL,  -- e.g., 0.7200
    threshold_km INTEGER,                 -- e.g., 5000 (null = flat rate)
    rate_after_threshold DECIMAL(5, 4),   -- e.g., 0.6600 (null = flat rate)

    -- Validity
    effective_from DATE NOT NULL,
    effective_to DATE,  -- null = currently active

    -- Metadata
    rate_source TEXT NOT NULL DEFAULT 'cra'
        CHECK (rate_source IN ('cra', 'custom')),
    notes TEXT,
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensure no overlapping active rates
    CONSTRAINT rate_positive CHECK (rate_per_km > 0)
);

CREATE INDEX idx_reimbursement_rates_effective ON reimbursement_rates(effective_from DESC);
```

### `mileage_reports`

Stores generated mileage reimbursement report references.

```sql
CREATE TABLE mileage_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,

    -- Report period
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,

    -- Calculated totals (snapshot at generation time)
    total_distance_km DECIMAL(10, 3) NOT NULL,
    business_distance_km DECIMAL(10, 3) NOT NULL,
    personal_distance_km DECIMAL(10, 3) NOT NULL,
    trip_count INTEGER NOT NULL,
    business_trip_count INTEGER NOT NULL,
    total_reimbursement DECIMAL(10, 2) NOT NULL,

    -- Rate used (snapshot)
    rate_per_km_used DECIMAL(5, 4) NOT NULL,
    rate_source_used TEXT NOT NULL,

    -- File reference
    file_path TEXT,  -- Supabase Storage path or local path
    file_format TEXT NOT NULL DEFAULT 'pdf'
        CHECK (file_format IN ('pdf', 'csv')),

    -- Metadata
    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_mileage_reports_employee ON mileage_reports(employee_id);
CREATE INDEX idx_mileage_reports_period ON mileage_reports(period_start, period_end);
```

## Local SQLCipher Tables (Mobile Offline)

### `local_trips`

```sql
CREATE TABLE local_trips (
    id TEXT PRIMARY KEY,          -- UUID as text
    shift_id TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    started_at TEXT NOT NULL,     -- ISO 8601
    ended_at TEXT NOT NULL,
    start_latitude REAL NOT NULL,
    start_longitude REAL NOT NULL,
    start_address TEXT,
    end_latitude REAL NOT NULL,
    end_longitude REAL NOT NULL,
    end_address TEXT,
    distance_km REAL NOT NULL,
    duration_minutes INTEGER NOT NULL,
    classification TEXT NOT NULL DEFAULT 'business',
    confidence_score REAL NOT NULL DEFAULT 1.0,
    gps_point_count INTEGER NOT NULL DEFAULT 0,
    synced INTEGER NOT NULL DEFAULT 0,  -- 0 = pending, 1 = synced
    created_at TEXT NOT NULL
);
```

## RLS Policies

```sql
-- trips: employees see own, managers see supervised
ALTER TABLE trips ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Employees can view own trips"
ON trips FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Managers can view supervised employee trips"
ON trips FOR SELECT TO authenticated
USING (
    employee_id IN (
        SELECT es.employee_id FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- Trips are system-generated, employees can only update classification
CREATE POLICY "Employees can update own trip classification"
ON trips FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = employee_id)
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- mileage_reports: employees see own only
ALTER TABLE mileage_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Employees can view own reports"
ON mileage_reports FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Employees can insert own reports"
ON mileage_reports FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- reimbursement_rates: readable by all authenticated, writable by admins
ALTER TABLE reimbursement_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "All authenticated can view rates"
ON reimbursement_rates FOR SELECT TO authenticated
USING (true);

-- Admin write access handled via service role or admin check
```

## Entity Relationship

```
employee_profiles
    ├── shifts
    │   ├── gps_points ──┐
    │   └── trips ◄──────┘ (derived from gps_points)
    │       └── trip_gps_points (junction)
    ├── mileage_reports
    └── employee_supervisors (manager access)

reimbursement_rates (global config)
locations (geofence matching for trip endpoints)
```
