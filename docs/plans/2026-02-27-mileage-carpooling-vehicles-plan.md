# Mileage Carpooling & Vehicle Periods Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add carpooling detection, vehicle period tracking, and company vehicle handling to the mileage system so only the driver with a personal vehicle gets reimbursed.

**Architecture:** New Supabase tables (`employee_vehicle_periods`, `carpool_groups`, `carpool_members`) with a `detect_carpools` RPC that runs after trip detection. Dashboard gets two new tabs (Vehicles, Carpooling) and the Flutter app shows carpool/vehicle badges on trips. Reimbursement logic updated server-side.

**Tech Stack:** PostgreSQL/Supabase (migrations), TypeScript/Next.js/shadcn (dashboard), Dart/Flutter/Riverpod (mobile app)

---

### Task 1: Migration 060 — employee_vehicle_periods table

**Files:**
- Create: `supabase/migrations/060_employee_vehicle_periods.sql`

**Step 1: Write the migration**

```sql
-- Migration 060: Employee vehicle periods
-- Tracks when employees have access to personal or company vehicles (period-based)

CREATE TABLE employee_vehicle_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    vehicle_type TEXT NOT NULL CHECK (vehicle_type IN ('personal', 'company')),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing period
    notes TEXT,
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_vehicle_periods_employee ON employee_vehicle_periods(employee_id);
CREATE INDEX idx_vehicle_periods_type ON employee_vehicle_periods(vehicle_type);
CREATE INDEX idx_vehicle_periods_dates ON employee_vehicle_periods(started_at, ended_at);

-- Prevent overlapping periods for the same employee + vehicle_type
CREATE OR REPLACE FUNCTION check_vehicle_period_overlap()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM employee_vehicle_periods
        WHERE employee_id = NEW.employee_id
          AND vehicle_type = NEW.vehicle_type
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
          AND started_at <= COALESCE(NEW.ended_at, '9999-12-31'::DATE)
          AND COALESCE(ended_at, '9999-12-31'::DATE) >= NEW.started_at
    ) THEN
        RAISE EXCEPTION 'Overlapping vehicle period exists for this employee and vehicle type';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_vehicle_period_overlap
    BEFORE INSERT OR UPDATE ON employee_vehicle_periods
    FOR EACH ROW EXECUTE FUNCTION check_vehicle_period_overlap();

-- Updated_at trigger
CREATE TRIGGER trg_vehicle_periods_updated_at
    BEFORE UPDATE ON employee_vehicle_periods
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE employee_vehicle_periods ENABLE ROW LEVEL SECURITY;

-- Admin/super_admin can do everything
CREATE POLICY "Admins manage vehicle periods"
    ON employee_vehicle_periods FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- Employees can view their own periods
CREATE POLICY "Employees view own vehicle periods"
    ON employee_vehicle_periods FOR SELECT
    USING (employee_id = auth.uid());

-- Helper function: check if employee has active vehicle period of a given type on a date
CREATE OR REPLACE FUNCTION has_active_vehicle_period(
    p_employee_id UUID,
    p_vehicle_type TEXT,
    p_date DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 FROM employee_vehicle_periods
        WHERE employee_id = p_employee_id
          AND vehicle_type = p_vehicle_type
          AND started_at <= p_date
          AND (ended_at IS NULL OR ended_at >= p_date)
    );
$$;

COMMENT ON TABLE employee_vehicle_periods IS 'Tracks periods when employees have access to personal or company vehicles';
COMMENT ON FUNCTION has_active_vehicle_period IS 'Check if employee has active vehicle period of given type on date';
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`
Expected: Migration applied successfully

**Step 3: Verify in Supabase**

Run: Query `SELECT * FROM employee_vehicle_periods LIMIT 0;` to confirm table exists.

**Step 4: Commit**

```bash
git add supabase/migrations/060_employee_vehicle_periods.sql
git commit -m "feat: add employee_vehicle_periods table (migration 060)"
```

---

### Task 2: Migration 061 — carpool_groups and carpool_members tables

**Files:**
- Create: `supabase/migrations/061_carpool_groups.sql`

**Step 1: Write the migration**

```sql
-- Migration 061: Carpool groups and members
-- Tracks detected carpooling between employees

CREATE TABLE carpool_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'auto_detected'
        CHECK (status IN ('auto_detected', 'confirmed', 'dismissed')),
    driver_employee_id UUID REFERENCES employee_profiles(id),
    review_needed BOOLEAN NOT NULL DEFAULT false,
    review_note TEXT,
    reviewed_by UUID REFERENCES employee_profiles(id),
    reviewed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_carpool_groups_date ON carpool_groups(trip_date DESC);
CREATE INDEX idx_carpool_groups_status ON carpool_groups(status);
CREATE INDEX idx_carpool_groups_review ON carpool_groups(review_needed) WHERE review_needed = true;

CREATE TABLE carpool_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carpool_group_id UUID NOT NULL REFERENCES carpool_groups(id) ON DELETE CASCADE,
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    role TEXT NOT NULL DEFAULT 'unassigned'
        CHECK (role IN ('driver', 'passenger', 'unassigned')),
    UNIQUE(carpool_group_id, trip_id),
    UNIQUE(trip_id)  -- a trip can only belong to one carpool group
);

CREATE INDEX idx_carpool_members_group ON carpool_members(carpool_group_id);
CREATE INDEX idx_carpool_members_trip ON carpool_members(trip_id);
CREATE INDEX idx_carpool_members_employee ON carpool_members(employee_id);

-- RLS for carpool_groups
ALTER TABLE carpool_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage carpool groups"
    ON carpool_groups FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Employees view own carpool groups"
    ON carpool_groups FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM carpool_members
            WHERE carpool_members.carpool_group_id = carpool_groups.id
              AND carpool_members.employee_id = auth.uid()
        )
    );

-- RLS for carpool_members
ALTER TABLE carpool_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage carpool members"
    ON carpool_members FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Employees view own carpool membership"
    ON carpool_members FOR SELECT
    USING (employee_id = auth.uid());

-- Employees can also see other members in their groups (to see who the driver is)
CREATE POLICY "Employees view group co-members"
    ON carpool_members FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM carpool_members AS my_membership
            WHERE my_membership.carpool_group_id = carpool_members.carpool_group_id
              AND my_membership.employee_id = auth.uid()
        )
    );

COMMENT ON TABLE carpool_groups IS 'Detected carpooling groups - employees who traveled together';
COMMENT ON TABLE carpool_members IS 'Members of carpool groups with driver/passenger roles';
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Commit**

```bash
git add supabase/migrations/061_carpool_groups.sql
git commit -m "feat: add carpool_groups and carpool_members tables (migration 061)"
```

---

### Task 3: Migration 062 — detect_carpools RPC

**Files:**
- Create: `supabase/migrations/062_detect_carpools_rpc.sql`

**Step 1: Write the migration**

The function uses the existing `haversine_km` function from migration 032. It compares all driving trips on a given date, finds pairs with similar start/end points and temporal overlap, groups them transitively, then assigns driver/passenger roles based on vehicle periods.

```sql
-- Migration 062: Carpooling detection RPC
-- Detects trips that are likely carpooling (same route, same time, different employees)

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
    DELETE FROM carpool_members
    WHERE carpool_group_id IN (
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
    WHERE started_at::DATE = p_date
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
    -- Simple approach: create groups, then merge
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
            -- Exactly one has personal vehicle: they're the driver
            SELECT t.employee_id INTO v_driver_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            WHERE tg.group_id = v_trip.group_id
              AND has_active_vehicle_period(t.employee_id, 'personal', p_date)
            LIMIT 1;
            v_needs_review := false;
        ELSIF v_personal_count = 0 THEN
            -- No one has personal vehicle: review needed
            v_driver_id := NULL;
            v_needs_review := true;
        ELSE
            -- Multiple have personal vehicles: pick first alphabetically, flag review
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

-- Admin RPC to update carpool group (change driver, confirm, dismiss)
CREATE OR REPLACE FUNCTION update_carpool_group(
    p_group_id UUID,
    p_status TEXT DEFAULT NULL,
    p_driver_employee_id UUID DEFAULT NULL,
    p_review_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Verify caller is admin
    IF NOT is_admin_or_super_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Only admins can update carpool groups';
    END IF;

    -- Update group
    UPDATE carpool_groups
    SET status = COALESCE(p_status, status),
        driver_employee_id = COALESCE(p_driver_employee_id, driver_employee_id),
        review_note = COALESCE(p_review_note, review_note),
        review_needed = CASE
            WHEN p_driver_employee_id IS NOT NULL THEN false
            ELSE review_needed
        END,
        reviewed_by = auth.uid(),
        reviewed_at = NOW()
    WHERE id = p_group_id;

    -- Update member roles if driver changed
    IF p_driver_employee_id IS NOT NULL THEN
        UPDATE carpool_members
        SET role = CASE
            WHEN employee_id = p_driver_employee_id THEN 'driver'
            ELSE 'passenger'
        END
        WHERE carpool_group_id = p_group_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION detect_carpools IS 'Detect carpooling trips on a given date based on proximity and temporal overlap';
COMMENT ON FUNCTION update_carpool_group IS 'Admin function to update carpool group status, driver, or review note';
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Test detect_carpools**

Run via Supabase SQL editor or RPC call:
```sql
SELECT * FROM detect_carpools('2026-02-27'::DATE);
```
Expected: Empty result (no matching trips yet) or detected groups if matching trips exist.

**Step 4: Commit**

```bash
git add supabase/migrations/062_detect_carpools_rpc.sql
git commit -m "feat: add detect_carpools and update_carpool_group RPCs (migration 062)"
```

---

### Task 4: Migration 063 — Update get_mileage_summary for carpooling and company vehicles

**Files:**
- Create: `supabase/migrations/063_update_mileage_summary.sql`

**Step 1: Write the migration**

This replaces the existing `get_mileage_summary` function to exclude:
- Trips where the employee is a carpool passenger
- Trips where the employee has an active company_vehicle period

```sql
-- Migration 063: Update get_mileage_summary for carpooling and company vehicles
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
    -- A trip is "reimbursable" if:
    --   classification = 'business'
    --   AND transport_mode = 'driving'
    --   AND no active company_vehicle period on trip date
    --   AND (not in a carpool group OR role = 'driver')
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

    -- Calculate YTD business km (Jan 1 to period_end, same reimbursable criteria)
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

    -- YTD before this period (for tiered calculation)
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
            -- Tiered: how many km at base rate vs reduced rate
            IF v_ytd_before >= v_threshold THEN
                -- All km at reduced rate
                v_reimbursement := v_business_km * v_rate_after;
            ELSIF (v_ytd_before + v_business_km) <= v_threshold THEN
                -- All km at base rate
                v_reimbursement := v_business_km * v_rate;
            ELSE
                -- Split between tiers
                v_reimbursement :=
                    (v_threshold - v_ytd_before) * v_rate +
                    (v_business_km - (v_threshold - v_ytd_before)) * v_rate_after;
            END IF;
        ELSE
            -- Flat rate
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
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Commit**

```bash
git add supabase/migrations/063_update_mileage_summary.sql
git commit -m "feat: update get_mileage_summary for carpooling and company vehicles (migration 063)"
```

---

### Task 5: Dashboard — TypeScript types for vehicle periods and carpooling

**Files:**
- Modify: `dashboard/src/types/mileage.ts`

**Step 1: Add the new interfaces**

Append to the end of `dashboard/src/types/mileage.ts`:

```typescript
export interface EmployeeVehiclePeriod {
  id: string;
  employee_id: string;
  vehicle_type: "personal" | "company";
  started_at: string;
  ended_at: string | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  // Joined
  employee?: { id: string; name: string };
}

export interface CarpoolGroup {
  id: string;
  trip_date: string;
  status: "auto_detected" | "confirmed" | "dismissed";
  driver_employee_id: string | null;
  review_needed: boolean;
  review_note: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
  // Joined
  members?: CarpoolMember[];
  driver?: { id: string; name: string };
}

export interface CarpoolMember {
  id: string;
  carpool_group_id: string;
  trip_id: string;
  employee_id: string;
  role: "driver" | "passenger" | "unassigned";
  // Joined
  employee?: { id: string; name: string };
  trip?: Trip;
}
```

**Step 2: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add TypeScript types for vehicle periods and carpooling"
```

---

### Task 6: Dashboard — Vehicle Management tab component

**Files:**
- Create: `dashboard/src/components/mileage/vehicle-periods-tab.tsx`
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx` (add the tab)

**Step 1: Create the VehiclePeriodsTab component**

This component shows a list of employee vehicle periods with add/edit/delete capabilities. Uses the same pattern as other dashboard components (separate Supabase queries, client-side merge with employee names, shadcn/ui components).

Key features:
- Table with columns: Employé, Type (Personnel/Entreprise), Début, Fin, Notes, Actions
- "Ajouter période" button → dialog with form (employee select, type select, dates, notes)
- Edit/Delete buttons per row
- Filters: vehicle type, active/expired, employee search
- Fetch employee_profiles separately and merge client-side (same pattern as trips page)

The component should:
1. Fetch `employee_vehicle_periods` ordered by `started_at DESC`
2. Fetch `employee_profiles` by IDs found in periods
3. Merge client-side via `employeeMap`
4. Render table with shadcn `Table` component
5. Add/Edit dialog with `Form`, `Select`, `Input`, `DatePicker` components

**Step 2: Add the tab to the mileage page**

In `dashboard/src/app/dashboard/mileage/page.tsx`, add a third tab:
- Import `VehiclePeriodsTab`
- Add `<TabsTrigger value="vehicles">Véhicules</TabsTrigger>` after the "clusters" trigger
- Add `<TabsContent value="vehicles"><VehiclePeriodsTab /></TabsContent>` after the clusters content

**Step 3: Commit**

```bash
git add dashboard/src/components/mileage/vehicle-periods-tab.tsx
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: add Vehicle Management tab to dashboard mileage page"
```

---

### Task 7: Dashboard — Carpooling tab component

**Files:**
- Create: `dashboard/src/components/mileage/carpooling-tab.tsx`
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx` (add the tab)

**Step 1: Create the CarpoolingTab component**

Key features:
- List of carpool groups with expandable details
- Each group card shows: date, member count, driver name, status badge, review badge
- Expanded view: member list with roles, trip details (start/end, distance)
- Actions: Confirm, Dismiss, Change Driver (dropdown of group members)
- "Re-détecter" button: date range picker → calls `detect_carpools` RPC for each date in range
- Filters: date range, status (auto_detected/confirmed/dismissed), review_needed toggle

Data fetching pattern:
1. Fetch `carpool_groups` ordered by `trip_date DESC`
2. Fetch `carpool_members` for those groups with trip_id
3. Fetch trips by IDs from members
4. Fetch employee_profiles by IDs
5. Merge client-side

Actions call the `update_carpool_group` RPC.

**Step 2: Add the tab to the mileage page**

Add `<TabsTrigger value="carpools">Covoiturages</TabsTrigger>` and corresponding `<TabsContent>`.

**Step 3: Commit**

```bash
git add dashboard/src/components/mileage/carpooling-tab.tsx
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: add Carpooling tab to dashboard mileage page"
```

---

### Task 8: Dashboard — Trips tab carpool and vehicle columns

**Files:**
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Add carpool and vehicle data to trips list**

In the trips tab, when fetching trips:
1. Also fetch `carpool_members` for the loaded trip IDs
2. Also fetch `employee_vehicle_periods` for the employee IDs + trip dates
3. Build lookup maps: `carpoolByTripId` and `vehiclePeriodByEmployeeDate`

Add two new columns to the trips table:
- **Covoiturage**: Badge showing "Conducteur" (green), "Passager" (orange), or "—"
- **Véhicule**: Badge showing "Personnel" (blue), "Entreprise" (purple), or "—"

Add a new filter chip for carpooling: "Covoiturage" (All / Oui / Non).

**Step 2: Commit**

```bash
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: add carpool and vehicle columns to dashboard trips list"
```

---

### Task 9: Flutter — Carpool model and provider

**Files:**
- Create: `gps_tracker/lib/features/mileage/models/carpool_info.dart`
- Modify: `gps_tracker/lib/features/mileage/providers/trip_provider.dart`
- Modify: `gps_tracker/lib/features/mileage/services/trip_service.dart`

**Step 1: Create CarpoolInfo model**

```dart
import 'package:flutter/foundation.dart';

enum CarpoolRole {
  driver,
  passenger,
  unassigned;

  factory CarpoolRole.fromJson(String value) {
    switch (value) {
      case 'driver':
        return CarpoolRole.driver;
      case 'passenger':
        return CarpoolRole.passenger;
      default:
        return CarpoolRole.unassigned;
    }
  }

  String get displayName {
    switch (this) {
      case CarpoolRole.driver:
        return 'Conducteur';
      case CarpoolRole.passenger:
        return 'Passager';
      case CarpoolRole.unassigned:
        return 'Non assigné';
    }
  }
}

@immutable
class CarpoolMemberInfo {
  final String employeeId;
  final String employeeName;
  final CarpoolRole role;

  const CarpoolMemberInfo({
    required this.employeeId,
    required this.employeeName,
    required this.role,
  });
}

/// Lightweight carpool info attached to a Trip for display purposes.
@immutable
class CarpoolInfo {
  final String groupId;
  final CarpoolRole myRole;
  final String? driverName;
  final List<CarpoolMemberInfo> members;

  const CarpoolInfo({
    required this.groupId,
    required this.myRole,
    this.driverName,
    this.members = const [],
  });

  bool get isPassenger => myRole == CarpoolRole.passenger;
  bool get isDriver => myRole == CarpoolRole.driver;
}
```

**Step 2: Add carpool fetching to TripService**

Add a method `getCarpoolInfoForTrips(List<String> tripIds)` to `TripService` that:
1. Queries `carpool_members` WHERE `trip_id IN (tripIds)`
2. For each match, queries `carpool_groups` and other members
3. Fetches employee names for group members
4. Returns `Map<String, CarpoolInfo>` keyed by trip_id

**Step 3: Add a provider for carpool info**

In `trip_provider.dart`, add:
```dart
final carpoolInfoProvider =
    FutureProvider.family<Map<String, CarpoolInfo>, List<String>>((ref, tripIds) async {
  final service = ref.read(tripServiceProvider);
  return service.getCarpoolInfoForTrips(tripIds);
});
```

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/mileage/models/carpool_info.dart
git add gps_tracker/lib/features/mileage/providers/trip_provider.dart
git add gps_tracker/lib/features/mileage/services/trip_service.dart
git commit -m "feat: add CarpoolInfo model and provider for Flutter"
```

---

### Task 10: Flutter — Vehicle period provider

**Files:**
- Modify: `gps_tracker/lib/features/mileage/services/trip_service.dart`
- Modify: `gps_tracker/lib/features/mileage/providers/trip_provider.dart`

**Step 1: Add vehicle period check to TripService**

Add a method `hasCompanyVehicle(String employeeId, DateTime date)` that:
1. Queries `employee_vehicle_periods` WHERE employee_id = employeeId AND vehicle_type = 'company' AND started_at <= date AND (ended_at IS NULL OR ended_at >= date)
2. Returns `bool`

Also add `getVehiclePeriodsForEmployee(String employeeId, DateTime start, DateTime end)` that returns all active periods in a date range for badge display.

**Step 2: Add a provider**

```dart
final hasCompanyVehicleProvider =
    FutureProvider.family<bool, TripPeriodParams>((ref, params) async {
  // Check if the employee has any active company vehicle period in the date range
  final service = ref.read(tripServiceProvider);
  return service.hasCompanyVehicleInRange(params.employeeId, params.start, params.end);
});
```

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/mileage/services/trip_service.dart
git add gps_tracker/lib/features/mileage/providers/trip_provider.dart
git commit -m "feat: add vehicle period check provider for Flutter"
```

---

### Task 11: Flutter — Carpool and vehicle badges on TripCard

**Files:**
- Create: `gps_tracker/lib/features/mileage/widgets/carpool_badge.dart`
- Create: `gps_tracker/lib/features/mileage/widgets/company_vehicle_badge.dart`
- Modify: `gps_tracker/lib/features/mileage/widgets/trip_card.dart`

**Step 1: Create CarpoolBadge widget**

```dart
import 'package:flutter/material.dart';
import '../models/carpool_info.dart';

class CarpoolBadge extends StatelessWidget {
  final CarpoolInfo carpoolInfo;

  const CarpoolBadge({super.key, required this.carpoolInfo});

  @override
  Widget build(BuildContext context) {
    final isPassenger = carpoolInfo.isPassenger;
    return Chip(
      avatar: Icon(
        isPassenger ? Icons.person : Icons.drive_eta,
        size: 14,
        color: isPassenger ? Colors.white : Colors.green.shade900,
      ),
      label: Text(
        isPassenger
            ? 'Passager${carpoolInfo.driverName != null ? ' · ${carpoolInfo.driverName}' : ''}'
            : 'Conducteur',
        style: TextStyle(
          fontSize: 11,
          color: isPassenger ? Colors.white : Colors.green.shade900,
        ),
      ),
      backgroundColor: isPassenger ? Colors.orange : Colors.green.shade100,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
```

**Step 2: Create CompanyVehicleBadge widget**

```dart
import 'package:flutter/material.dart';

class CompanyVehicleBadge extends StatelessWidget {
  const CompanyVehicleBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.business, size: 14, color: Colors.white),
      label: const Text(
        'Véh. entreprise',
        style: TextStyle(fontSize: 11, color: Colors.white),
      ),
      backgroundColor: Colors.purple,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
```

**Step 3: Update TripCard**

Modify `TripCard` to accept optional `CarpoolInfo? carpoolInfo` and `bool hasCompanyVehicle` parameters. In the bottom Row (line 84-103 of current trip_card.dart), add the new badges:

```dart
class TripCard extends StatelessWidget {
  final Trip trip;
  final CarpoolInfo? carpoolInfo;  // NEW
  final bool hasCompanyVehicle;     // NEW
  final VoidCallback? onTap;
  final VoidCallback? onClassificationToggle;

  const TripCard({
    super.key,
    required this.trip,
    this.carpoolInfo,              // NEW
    this.hasCompanyVehicle = false, // NEW
    this.onTap,
    this.onClassificationToggle,
  });
```

In the metrics Row, add badges between MatchStatusBadge and TripClassificationChip:
```dart
if (carpoolInfo != null) ...[
  const SizedBox(width: 4),
  CarpoolBadge(carpoolInfo: carpoolInfo!),
],
if (hasCompanyVehicle) ...[
  const SizedBox(width: 4),
  const CompanyVehicleBadge(),
],
```

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/mileage/widgets/carpool_badge.dart
git add gps_tracker/lib/features/mileage/widgets/company_vehicle_badge.dart
git add gps_tracker/lib/features/mileage/widgets/trip_card.dart
git commit -m "feat: add carpool and company vehicle badges to TripCard"
```

---

### Task 12: Flutter — Update MileageScreen to pass carpool/vehicle data to TripCard

**Files:**
- Modify: `gps_tracker/lib/features/mileage/screens/mileage_screen.dart`

**Step 1: Fetch carpool and vehicle data alongside trips**

In `MileageScreen`, after the `tripsAsync` watch, also watch:
1. `carpoolInfoProvider` with the list of trip IDs from the loaded trips
2. `hasCompanyVehicleProvider` for the current employee/period

Since carpool info depends on trip IDs (which come from tripsAsync), use a derived provider or fetch inline.

Simple approach: after trips load, fire a separate fetch for carpool info using the trip IDs. Use a `StateProvider` or `FutureProvider` that depends on the trips.

Pass the data to each `TripCard`:
```dart
TripCard(
  trip: trip,
  carpoolInfo: carpoolMap[trip.id],
  hasCompanyVehicle: companyVehicleDates.contains(trip.startedAt.toLocal().toDateString()),
  onTap: () => _navigateToTripDetail(context, trip),
  onClassificationToggle: () => _toggleClassification(trip),
),
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/mileage/screens/mileage_screen.dart
git commit -m "feat: pass carpool and vehicle data to TripCard in MileageScreen"
```

---

### Task 13: Flutter — Update TripDetailScreen with carpool section

**Files:**
- Modify: `gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart`

**Step 1: Add carpool section**

When the trip has carpool info, show a "Covoiturage" section with:
- Group status (auto-detected / confirmed)
- Member list with roles and names
- If passenger: "0 km remboursé — vous étiez passager"
- If driver: "Vous êtes le conducteur"

Also show company vehicle badge if applicable, with message: "Véhicule d'entreprise — 0 km remboursé"

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart
git commit -m "feat: add carpool and vehicle info section to TripDetailScreen"
```

---

### Task 14: Sync service — Trigger carpool detection after trip detection

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart`

**Step 1: Add carpool detection call**

In `_triggerTripDetection()` (line ~391), after each `detect_trips` RPC call completes successfully, fire a `detect_carpools` RPC for the trip date:

```dart
// After detect_trips completes for a shift:
_supabase.rpc('detect_carpools', params: {
  'p_date': DateTime.now().toIso8601String().substring(0, 10), // YYYY-MM-DD
}).then((_) {
  _logger?.sync(Severity.debug, 'Carpool detection completed');
}).catchError((e) {
  _logger?.sync(Severity.warn, 'Carpool detection failed', metadata: {'error': e.toString()});
});
```

This is fire-and-forget (same pattern as existing trip detection). The carpool detection handles idempotency internally.

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/sync_service.dart
git commit -m "feat: trigger carpool detection after trip detection in sync service"
```

---

### Task 15: Update CLAUDE.md and memory with new migration numbers

**Files:**
- Modify: `CLAUDE.md` (update migration numbering section)
- Modify: memory file

**Step 1: Update migration numbers**

Add to the migration numbering section in memory:
- 060: employee_vehicle_periods (vehicle period tracking)
- 061: carpool_groups (carpool_groups + carpool_members tables)
- 062: detect_carpools_rpc (detect_carpools + update_carpool_group RPCs)
- 063: update_mileage_summary (reimbursement excludes passengers + company vehicles)

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update migration numbering for carpooling feature"
```
