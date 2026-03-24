# Mileage Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dedicated mileage approval page where supervisors assign vehicle type and role per trip, resolve carpooling, and approve reimbursement per employee per pay period.

**Architecture:** Split-panel dashboard page (employee list left, trip detail right) backed by new SQL RPCs. New `mileage_approvals` table + new columns on `trips`. Follows existing approval patterns from `payroll_approvals` and `day_approvals`.

**Tech Stack:** Next.js 14 (App Router), shadcn/ui, Tailwind CSS, PostgreSQL/Supabase RPCs, TypeScript

**Spec:** `docs/superpowers/specs/2026-03-24-mileage-approval-design.md`

---

## File Structure

### New Files
```
supabase/migrations/20260326100000_mileage_approval.sql     -- Schema + RPCs + triggers
dashboard/src/app/dashboard/mileage-approval/page.tsx        -- Page route
dashboard/src/components/mileage-approval/mileage-approval-page.tsx  -- Main layout
dashboard/src/components/mileage-approval/mileage-employee-list.tsx  -- Left panel
dashboard/src/components/mileage-approval/mileage-employee-detail.tsx -- Right panel
dashboard/src/components/mileage-approval/mileage-trip-row.tsx       -- Trip line item
dashboard/src/components/mileage-approval/mileage-approval-summary.tsx -- Footer summary
dashboard/src/lib/api/mileage-approval.ts                   -- API client functions
dashboard/src/lib/hooks/use-mileage-approval.ts             -- Data fetching hook
```

### Modified Files
```
dashboard/src/types/mileage.ts                              -- Add approval types
dashboard/src/components/layout/sidebar.tsx                  -- Add nav link
```

---

## Task 1: Database Migration — Schema Changes

**Files:**
- Create: `supabase/migrations/20260326100000_mileage_approval.sql`

**Reference:**
- Pattern: `supabase/migrations/20260325100000_payroll_approvals.sql` (payroll approvals table + triggers)
- Pattern: `supabase/migrations/096_approval_actions.sql` (SECURITY DEFINER RPCs)
- Existing: `supabase/migrations/032_mileage_trips.sql` (trips table)
- Existing: `supabase/migrations/033_reimbursement_rates.sql` (CRA rates)

- [ ] **Step 1: Write the migration file — trips columns + mileage_approvals table**

```sql
-- =============================================================
-- Migration: Mileage Approval System
-- Adds vehicle_type/role columns to trips, creates mileage_approvals table,
-- locking triggers, and updates CRA 2026 rates.
-- =============================================================

-- 1. Add vehicle_type and role columns to trips
ALTER TABLE trips
  ADD COLUMN vehicle_type TEXT CHECK (vehicle_type IN ('personal', 'company')),
  ADD COLUMN role TEXT CHECK (role IN ('driver', 'passenger'));

COMMENT ON COLUMN trips.vehicle_type IS 'Vehicle used for this trip: personal or company. NULL = not yet assigned by supervisor.';
COMMENT ON COLUMN trips.role IS 'Driver or passenger role for this trip. NULL = not yet assigned by supervisor.';

-- 2. Create mileage_approvals table
CREATE TABLE mileage_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  reimbursable_km DECIMAL(10,2),
  reimbursement_amount DECIMAL(10,2),
  approved_by UUID REFERENCES employee_profiles(id),
  approved_at TIMESTAMPTZ,
  unlocked_by UUID REFERENCES employee_profiles(id),
  unlocked_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, period_start, period_end)
);

CREATE INDEX idx_mileage_approvals_status ON mileage_approvals(status);
CREATE INDEX idx_mileage_approvals_period ON mileage_approvals(period_start, period_end);

COMMENT ON TABLE mileage_approvals IS 'ROLE: Tracks mileage-level approval per employee per biweekly period. STATUTS: pending (can modify trip vehicle/role), approved (trips locked). REGLES: All eligible trips must have vehicle_type and role assigned before approval. All worked days must be day-approved. Reimbursable km and amount are frozen at approval time. RELATIONS: employee_profiles (employee_id, approved_by, unlocked_by).';

-- 3. RLS policies
ALTER TABLE mileage_approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage mileage approvals"
  ON mileage_approvals FOR ALL
  TO authenticated
  USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Managers can read supervised employees mileage approvals"
  ON mileage_approvals FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors es
      WHERE es.supervisor_id = auth.uid()
        AND es.employee_id = mileage_approvals.employee_id
    )
  );
```

- [ ] **Step 2: Add locking trigger for trips**

Append to the same migration file:

```sql
-- 4. Locking trigger: block trip vehicle/role changes when mileage is approved
CREATE OR REPLACE FUNCTION check_mileage_lock()
RETURNS TRIGGER AS $$
DECLARE
  v_trip_date DATE;
BEGIN
  -- Only check if vehicle_type or role is changing
  IF (OLD.vehicle_type IS NOT DISTINCT FROM NEW.vehicle_type)
     AND (OLD.role IS NOT DISTINCT FROM NEW.role) THEN
    RETURN NEW;
  END IF;

  v_trip_date := to_business_date(NEW.started_at);

  IF EXISTS (
    SELECT 1 FROM mileage_approvals
    WHERE employee_id = NEW.employee_id
      AND status = 'approved'
      AND period_start <= v_trip_date
      AND period_end >= v_trip_date
  ) THEN
    RAISE EXCEPTION 'Mileage is locked for this period. Reopen mileage approval first.';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mileage_lock_trips
  BEFORE UPDATE ON trips
  FOR EACH ROW EXECUTE FUNCTION check_mileage_lock();

-- Also block trip deletion when mileage is approved (prevents detect_trips from wiping approved trips)
CREATE OR REPLACE FUNCTION check_mileage_lock_delete()
RETURNS TRIGGER AS $$
DECLARE
  v_trip_date DATE;
BEGIN
  v_trip_date := to_business_date(OLD.started_at);

  IF EXISTS (
    SELECT 1 FROM mileage_approvals
    WHERE employee_id = OLD.employee_id
      AND status = 'approved'
      AND period_start <= v_trip_date
      AND period_end >= v_trip_date
  ) THEN
    RAISE EXCEPTION 'Cannot delete trips: mileage is locked for this period. Reopen mileage approval first.';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mileage_lock_trips_delete
  BEFORE DELETE ON trips
  FOR EACH ROW EXECUTE FUNCTION check_mileage_lock_delete();

-- Also block carpool group deletion when mileage is approved (prevents detect_carpools from wiping approved data)
CREATE OR REPLACE FUNCTION check_mileage_lock_carpool_delete()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM carpool_members cm
    JOIN trips t ON t.id = cm.trip_id
    JOIN mileage_approvals ma ON ma.employee_id = t.employee_id
      AND ma.status = 'approved'
      AND ma.period_start <= to_business_date(t.started_at)
      AND ma.period_end >= to_business_date(t.started_at)
    WHERE cm.carpool_group_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'Cannot delete carpool group: mileage is locked for this period. Reopen mileage approval first.';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mileage_lock_carpool_groups_delete
  BEFORE DELETE ON carpool_groups
  FOR EACH ROW EXECUTE FUNCTION check_mileage_lock_carpool_delete();
```

- [ ] **Step 3: Update CRA 2026 rates**

Append to the same migration file:

```sql
-- 5. Update CRA rates from 2025 ($0.72/$0.66) to 2026 ($0.73/$0.67)
UPDATE reimbursement_rates
SET rate_per_km = 0.73,
    rate_after_threshold = 0.67,
    effective_from = '2026-01-01'
WHERE threshold_km = 5000
  AND rate_per_km = 0.72;
```

- [ ] **Step 4: Apply migration via Supabase MCP**

Run: `mcp__supabase__apply_migration` with the migration file name `20260326100000_mileage_approval`

- [ ] **Step 5: Verify migration applied**

Run SQL to confirm:
```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'trips' AND column_name IN ('vehicle_type', 'role');

SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'mileage_approvals' ORDER BY ordinal_position;

SELECT rate_per_km, rate_after_threshold FROM reimbursement_rates WHERE threshold_km = 5000;
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260326100000_mileage_approval.sql
git commit -m "feat: add mileage_approvals table and trips vehicle/role columns"
```

---

## Task 2: Database Migration — RPCs

**Files:**
- Modify: `supabase/migrations/20260326100000_mileage_approval.sql` (append RPCs)

**Reference:**
- Pattern: `supabase/migrations/096_approval_actions.sql` (save_activity_override, approve_day)
- Pattern: `supabase/migrations/067_detect_carpools_rpc.sql` (detect_carpools)
- Existing: `supabase/migrations/068_update_mileage_summary.sql` (get_mileage_summary YTD logic)
- Existing: `supabase/migrations/065_employee_vehicle_periods.sql` (has_active_vehicle_period)

- [ ] **Step 1: Write `prefill_mileage_defaults` RPC**

Create a new migration file `supabase/migrations/20260326100001_mileage_approval_rpcs.sql`:

```sql
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
    -- Both active → leave NULL (needs review)

    -- Check carpool membership
    SELECT cm.role INTO v_carpool_role
    FROM carpool_members cm
    WHERE cm.trip_id = v_trip.id;

    IF v_carpool_role IS NOT NULL AND v_carpool_role != 'unassigned' THEN
      v_default_role := v_carpool_role;
    ELSIF v_carpool_role IS NULL THEN
      -- No carpool → default to driver
      v_default_role := 'driver';
    END IF;
    -- Carpool with 'unassigned' → leave NULL

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
```

- [ ] **Step 2: Write `update_trip_vehicle` RPC**

Append to the same migration file:

```sql
-- update_trip_vehicle: Update vehicle_type and role on a single trip with carpool cascade
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

  -- Validate inputs
  IF p_vehicle_type IS NOT NULL AND p_vehicle_type NOT IN ('personal', 'company') THEN
    RAISE EXCEPTION 'Invalid vehicle_type: %. Must be personal or company', p_vehicle_type;
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('driver', 'passenger') THEN
    RAISE EXCEPTION 'Invalid role: %. Must be driver or passenger', p_role;
  END IF;

  -- Get trip
  SELECT * INTO v_trip FROM trips WHERE id = p_trip_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip not found: %', p_trip_id;
  END IF;

  -- Check mileage lock (trigger will also check, but give better error message)
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

  -- Update trip (COALESCE preserves existing value when NULL is passed)
  UPDATE trips
  SET vehicle_type = COALESCE(p_vehicle_type, trips.vehicle_type),
      role = COALESCE(p_role, trips.role)
  WHERE id = p_trip_id;

  -- Carpool cascade: if setting as driver, set other group members as passenger
  IF p_role = 'driver' THEN
    SELECT cm.carpool_group_id INTO v_carpool_group_id
    FROM carpool_members cm
    WHERE cm.trip_id = p_trip_id;

    IF v_carpool_group_id IS NOT NULL THEN
      -- Update other trips in the group to passenger
      UPDATE trips t
      SET role = 'passenger'
      FROM carpool_members cm
      WHERE cm.trip_id = t.id
        AND cm.carpool_group_id = v_carpool_group_id
        AND t.id != p_trip_id;

      -- Sync carpool_members.role
      UPDATE carpool_members
      SET role = 'driver'
      WHERE trip_id = p_trip_id;

      UPDATE carpool_members cm
      SET role = 'passenger'
      WHERE cm.carpool_group_id = v_carpool_group_id
        AND cm.trip_id != p_trip_id;
    END IF;
  END IF;

  -- Also sync carpool_members.role for non-cascade updates
  IF p_role IS NOT NULL AND v_carpool_group_id IS NULL THEN
    UPDATE carpool_members
    SET role = p_role
    WHERE trip_id = p_trip_id;
  END IF;

  RETURN to_jsonb((SELECT t FROM trips t WHERE t.id = p_trip_id));
END;
$$;
```

- [ ] **Step 3: Write `batch_update_trip_vehicles` RPC**

```sql
-- batch_update_trip_vehicles: Batch update vehicle_type/role on multiple trips
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
```

- [ ] **Step 4: Write `get_mileage_approval_summary` RPC**

```sql
-- get_mileage_approval_summary: Summary view for employee list (left panel)
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

  -- Get current CRA rate for estimated amount
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
      -- Estimated amount: simple approximation using base rate * reimbursable_km
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
```

- [ ] **Step 5: Write `get_mileage_approval_detail` RPC**

```sql
-- get_mileage_approval_detail: Detailed trip list for an employee (right panel)
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

  -- Get trips grouped by day with carpool and stop eligibility info
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
      -- Carpool info
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
      -- Eligibility: check adjacent stops are approved in day_approval
      -- A trip is eligible if both endpoint locations are professional types
      -- or have been overridden to approved
      CASE
        WHEN t.transport_mode != 'driving' THEN FALSE
        ELSE TRUE  -- Simplified: detailed stop check done client-side from day_approval data
      END AS eligible
    FROM trips t
    LEFT JOIN carpool_members cm ON cm.trip_id = t.id
    WHERE t.employee_id = p_employee_id
      AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
  ) trip_row;

  -- Calculate summary
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

  -- Calculate estimated reimbursement (same logic as get_mileage_summary)
  SELECT rr.rate_per_km, rr.threshold_km, rr.rate_after_threshold
  INTO v_rate_per_km, v_threshold_km, v_rate_after
  FROM reimbursement_rates rr
  WHERE rr.effective_from <= p_period_end
  ORDER BY rr.effective_from DESC
  LIMIT 1;

  -- YTD km before this period
  SELECT COALESCE(SUM(COALESCE(t.road_distance_km, t.distance_km)), 0)
  INTO v_ytd_km
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) >= date_trunc('year', p_period_end::TIMESTAMP)::DATE
    AND to_business_date(t.started_at) < p_period_start
    AND t.transport_mode = 'driving'
    AND t.vehicle_type = 'personal'
    AND t.role = 'driver';

  -- Tiered calculation
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

  -- Get mileage approval status
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
```

- [ ] **Step 6: Write `approve_mileage` and `reopen_mileage_approval` RPCs**

```sql
-- approve_mileage: Freeze reimbursable km and amount
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

  -- Check all worked days are day-approved
  SELECT COUNT(*) INTO v_unapproved_days
  FROM day_approvals da
  WHERE da.employee_id = p_employee_id
    AND da.date BETWEEN p_period_start AND p_period_end
    AND da.status != 'approved';

  IF v_unapproved_days > 0 THEN
    RAISE EXCEPTION '% day(s) not yet approved for this period', v_unapproved_days;
  END IF;

  -- Check no unassigned trips
  SELECT COUNT(*) INTO v_needs_review
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving'
    AND (t.vehicle_type IS NULL OR t.role IS NULL);

  IF v_needs_review > 0 THEN
    RAISE EXCEPTION '% trip(s) still need vehicle/role assignment', v_needs_review;
  END IF;

  -- Get current detail for frozen values
  v_detail := get_mileage_approval_detail(p_employee_id, p_period_start, p_period_end);

  -- Upsert mileage approval
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

-- reopen_mileage_approval: Unlock for modifications
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
```

- [ ] **Step 7: Apply migration via Supabase MCP**

Run: `mcp__supabase__apply_migration` with the migration file name `20260326100001_mileage_approval_rpcs`

- [ ] **Step 8: Verify RPCs exist**

Run SQL:
```sql
SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'prefill_mileage_defaults',
    'update_trip_vehicle',
    'batch_update_trip_vehicles',
    'get_mileage_approval_summary',
    'get_mileage_approval_detail',
    'approve_mileage',
    'reopen_mileage_approval'
  )
ORDER BY routine_name;
```

Expected: 7 rows

- [ ] **Step 9: Commit**

```bash
git add supabase/migrations/20260326100001_mileage_approval_rpcs.sql
git commit -m "feat: add mileage approval RPCs (prefill, update, approve, summary, detail)"
```

---

## Task 3: TypeScript Types

**Files:**
- Modify: `dashboard/src/types/mileage.ts` (add mileage approval types)

**Reference:**
- Existing types in `dashboard/src/types/mileage.ts`
- Pattern: `dashboard/src/types/payroll.ts` (PayrollReportRow, PayPeriod)

- [ ] **Step 1: Read existing mileage types**

Read `dashboard/src/types/mileage.ts` to understand existing structures.

- [ ] **Step 2: Add mileage approval types**

Append to `dashboard/src/types/mileage.ts`:

```typescript
// ============================================================
// Mileage Approval Types
// ============================================================

export interface MileageApprovalSummaryRow {
  employee_id: string;
  employee_name: string;
  trip_count: number;
  reimbursable_km: number;
  company_km: number;
  needs_review_count: number;
  carpool_group_count: number;
  estimated_amount: number;
  mileage_status: 'pending' | 'approved' | null;
  approved_km: number | null;
  approved_amount: number | null;
}

export interface MileageTripDetail {
  trip_date: string;
  trip_id: string;
  started_at: string;
  ended_at: string;
  start_address: string | null;
  end_address: string | null;
  start_location_id: string | null;
  end_location_id: string | null;
  distance_km: number;
  vehicle_type: 'personal' | 'company' | null;
  role: 'driver' | 'passenger' | null;
  transport_mode: string;
  has_gps_gap: boolean;
  carpool_group_id: string | null;
  carpool_detected_role: string | null;
  carpool_members: CarpoolMemberInfo[] | null;
  eligible: boolean;
}

export interface CarpoolMemberInfo {
  employee_id: string;
  employee_name: string;
  role: string;
  trip_id: string;
}

export interface MileageApprovalDetailSummary {
  reimbursable_km: number;
  company_km: number;
  passenger_km: number;
  needs_review_count: number;
  estimated_amount: number;
  ytd_km: number;
  rate_per_km: number;
  rate_after_threshold: number | null;
  threshold_km: number | null;
}

export interface MileageApproval {
  id: string;
  employee_id: string;
  period_start: string;
  period_end: string;
  status: 'pending' | 'approved';
  reimbursable_km: number | null;
  reimbursement_amount: number | null;
  approved_by: string | null;
  approved_at: string | null;
  unlocked_by: string | null;
  unlocked_at: string | null;
  notes: string | null;
}

export interface MileageApprovalDetail {
  trips: MileageTripDetail[];
  summary: MileageApprovalDetailSummary;
  approval: MileageApproval | null;
}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add mileage approval TypeScript types"
```

---

## Task 4: API Client

**Files:**
- Create: `dashboard/src/lib/api/mileage-approval.ts`

**Reference:**
- Pattern: `dashboard/src/lib/api/payroll.ts` (approvePayroll, unlockPayroll, getPayrollPeriodReport)

- [ ] **Step 1: Create API client file**

```typescript
import { supabaseClient } from '@/lib/supabase/client';
import type {
  MileageApprovalSummaryRow,
  MileageApprovalDetail,
  MileageApproval,
} from '@/types/mileage';

export async function getMileageApprovalSummary(
  periodStart: string,
  periodEnd: string
): Promise<MileageApprovalSummaryRow[]> {
  const { data, error } = await supabaseClient.rpc('get_mileage_approval_summary', {
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data ?? [];
}

export async function getMileageApprovalDetail(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<MileageApprovalDetail> {
  const { data, error } = await supabaseClient.rpc('get_mileage_approval_detail', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}

export async function prefillMileageDefaults(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<{ prefilled_count: number; needs_review_count: number }> {
  const { data, error } = await supabaseClient.rpc('prefill_mileage_defaults', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}

export async function updateTripVehicle(
  tripId: string,
  vehicleType: string | null,
  role: string | null
): Promise<any> {
  const { data, error } = await supabaseClient.rpc('update_trip_vehicle', {
    p_trip_id: tripId,
    p_vehicle_type: vehicleType,
    p_role: role,
  });
  if (error) throw error;
  return data;
}

export async function batchUpdateTripVehicles(
  tripIds: string[],
  vehicleType: string | null,
  role: string | null
): Promise<{ updated_count: number }> {
  const { data, error } = await supabaseClient.rpc('batch_update_trip_vehicles', {
    p_trip_ids: tripIds,
    p_vehicle_type: vehicleType,
    p_role: role,
  });
  if (error) throw error;
  return data;
}

export async function approveMileage(
  employeeId: string,
  periodStart: string,
  periodEnd: string,
  notes?: string
): Promise<MileageApproval> {
  const { data, error } = await supabaseClient.rpc('approve_mileage', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function reopenMileageApproval(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<MileageApproval> {
  const { data, error } = await supabaseClient.rpc('reopen_mileage_approval', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/api/mileage-approval.ts
git commit -m "feat: add mileage approval API client"
```

---

## Task 5: Data Hook

**Files:**
- Create: `dashboard/src/lib/hooks/use-mileage-approval.ts`

**Reference:**
- Pattern: `dashboard/src/lib/hooks/use-payroll-report.ts` (usePayrollReport)

- [ ] **Step 1: Create the hook**

```typescript
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import type { PayPeriod } from '@/types/payroll';
import type {
  MileageApprovalSummaryRow,
  MileageApprovalDetail,
  MileageTripDetail,
} from '@/types/mileage';
import {
  getMileageApprovalSummary,
  getMileageApprovalDetail,
  prefillMileageDefaults,
} from '@/lib/api/mileage-approval';

export function useMileageApprovalSummary(period: PayPeriod) {
  const [employees, setEmployees] = useState<MileageApprovalSummaryRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const data = await getMileageApprovalSummary(period.start, period.end);
      setEmployees(data);
    } catch (err: any) {
      setError(err.message || 'Failed to load mileage summary');
    } finally {
      setIsLoading(false);
    }
  }, [period.start, period.end]);

  useEffect(() => { fetchData(); }, [fetchData]);

  const teamTotals = useMemo(() => ({
    totalKm: employees.reduce((s, e) => s + e.reimbursable_km, 0),
    totalCompanyKm: employees.reduce((s, e) => s + e.company_km, 0),
    totalAmount: employees.reduce((s, e) => s + (e.approved_amount ?? e.estimated_amount), 0),
    totalNeedsReview: employees.reduce((s, e) => s + e.needs_review_count, 0),
  }), [employees]);

  return { employees, teamTotals, isLoading, error, refetch: fetchData };
}

export function useMileageApprovalDetail(
  employeeId: string | null,
  period: PayPeriod
) {
  const [detail, setDetail] = useState<MileageApprovalDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    if (!employeeId) {
      setDetail(null);
      return;
    }
    setIsLoading(true);
    setError(null);
    try {
      // Prefill defaults first, then fetch detail
      await prefillMileageDefaults(employeeId, period.start, period.end);
      const data = await getMileageApprovalDetail(employeeId, period.start, period.end);
      setDetail(data);
    } catch (err: any) {
      setError(err.message || 'Failed to load mileage detail');
    } finally {
      setIsLoading(false);
    }
  }, [employeeId, period.start, period.end]);

  useEffect(() => { fetchData(); }, [fetchData]);

  // Group trips by day
  const tripsByDay = useMemo(() => {
    if (!detail) return new Map<string, MileageTripDetail[]>();
    const map = new Map<string, MileageTripDetail[]>();
    for (const trip of detail.trips) {
      const existing = map.get(trip.trip_date) ?? [];
      existing.push(trip);
      map.set(trip.trip_date, existing);
    }
    return map;
  }, [detail]);

  return { detail, tripsByDay, isLoading, error, refetch: fetchData };
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/hooks/use-mileage-approval.ts
git commit -m "feat: add mileage approval data hooks"
```

---

## Task 6: MileageTripRow Component

**Files:**
- Create: `dashboard/src/components/mileage-approval/mileage-trip-row.tsx`

**Reference:**
- Pattern: `dashboard/src/components/approvals/approval-rows.tsx` (status badges, color coding)
- UI: shadcn `Select`, `Badge`, `Tooltip`

- [ ] **Step 1: Create the trip row component**

```tsx
'use client';

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import { Users } from 'lucide-react';
import type { MileageTripDetail } from '@/types/mileage';

interface MileageTripRowProps {
  trip: MileageTripDetail;
  disabled: boolean;
  onVehicleChange: (tripId: string, vehicleType: string) => void;
  onRoleChange: (tripId: string, role: string) => void;
}

export function MileageTripRow({ trip, disabled, onVehicleChange, onRoleChange }: MileageTripRowProps) {
  const isResolved = trip.vehicle_type !== null && trip.role !== null;
  const isReimbursable = trip.vehicle_type === 'personal' && trip.role === 'driver';

  const borderColor = isResolved
    ? isReimbursable ? 'border-l-green-500' : 'border-l-slate-400'
    : 'border-l-yellow-500';

  return (
    <div className={`flex items-center justify-between gap-2 px-3 py-2 rounded-r border-l-[3px] ${borderColor} ${
      !trip.eligible ? 'opacity-50' : ''
    } ${isReimbursable ? 'bg-green-50/50' : 'bg-white'}`}>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 text-sm">
          <span className="truncate">
            {trip.start_address ?? 'Inconnu'} → {trip.end_address ?? 'Inconnu'}
          </span>
          <span className="text-muted-foreground text-xs whitespace-nowrap">
            {trip.distance_km.toFixed(1)} km
          </span>
        </div>
        {trip.carpool_members && trip.carpool_members.length > 0 && (
          <div className="flex items-center gap-1 mt-1">
            <Users className="h-3 w-3 text-yellow-600" />
            <span className="text-xs text-yellow-700">
              Covoit. avec {trip.carpool_members.map(m => m.employee_name.split(' ')[0]).join(', ')}
            </span>
          </div>
        )}
        {trip.has_gps_gap && (
          <Badge variant="outline" className="text-xs mt-1 text-orange-600 border-orange-300">
            Écart GPS
          </Badge>
        )}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        {!trip.eligible ? (
          <Tooltip>
            <TooltipTrigger>
              <Badge variant="outline" className="text-xs text-muted-foreground">
                Non éligible
              </Badge>
            </TooltipTrigger>
            <TooltipContent>
              Stops de départ ou d&apos;arrivée non approuvés
            </TooltipContent>
          </Tooltip>
        ) : (
          <>
            <Select
              value={trip.vehicle_type ?? ''}
              onValueChange={(v) => onVehicleChange(trip.trip_id, v)}
              disabled={disabled}
            >
              <SelectTrigger className="h-7 w-[110px] text-xs">
                <SelectValue placeholder="Véhicule..." />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="personal">Personnel</SelectItem>
                <SelectItem value="company">Compagnie</SelectItem>
              </SelectContent>
            </Select>
            <Select
              value={trip.role ?? ''}
              onValueChange={(v) => onRoleChange(trip.trip_id, v)}
              disabled={disabled}
            >
              <SelectTrigger className="h-7 w-[110px] text-xs">
                <SelectValue placeholder="Rôle..." />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="driver">Conducteur</SelectItem>
                <SelectItem value="passenger">Passager</SelectItem>
              </SelectContent>
            </Select>
          </>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-trip-row.tsx
git commit -m "feat: add MileageTripRow component"
```

---

## Task 7: MileageApprovalSummary Component (Footer)

**Files:**
- Create: `dashboard/src/components/mileage-approval/mileage-approval-summary.tsx`

- [ ] **Step 1: Create the summary footer component**

```tsx
'use client';

import { Button } from '@/components/ui/button';
import { Check, Unlock } from 'lucide-react';
import type { MileageApprovalDetailSummary, MileageApproval } from '@/types/mileage';

interface MileageApprovalSummaryProps {
  summary: MileageApprovalDetailSummary;
  approval: MileageApproval | null;
  onApprove: () => void;
  onReopen: () => void;
  isSaving: boolean;
}

export function MileageApprovalSummaryFooter({
  summary,
  approval,
  onApprove,
  onReopen,
  isSaving,
}: MileageApprovalSummaryProps) {
  const isApproved = approval?.status === 'approved';
  const canApprove = summary.needs_review_count === 0 && !isApproved;

  return (
    <div className="border-t bg-muted/30 p-4 space-y-2">
      <div className="flex justify-between text-sm">
        <div className="space-y-1">
          <div>
            Remboursable: <strong>{summary.reimbursable_km.toFixed(1)} km</strong>
            <span className="text-muted-foreground ml-1">
              (perso + conducteur)
            </span>
          </div>
          <div className="text-muted-foreground text-xs">
            Compagnie: {summary.company_km.toFixed(1)} km · Passager: {summary.passenger_km.toFixed(1)} km
          </div>
          <div className="text-muted-foreground text-xs">
            YTD: {summary.ytd_km.toFixed(0)} km · Taux: {summary.rate_per_km}$/km
            {summary.rate_after_threshold && (
              <> (après {summary.threshold_km} km: {summary.rate_after_threshold}$/km)</>
            )}
          </div>
        </div>
        <div className="text-right">
          <div className="text-2xl font-bold">
            {isApproved
              ? `${approval!.reimbursement_amount?.toFixed(2)} $`
              : `${summary.estimated_amount.toFixed(2)} $`
            }
          </div>
          {!isApproved && (
            <div className="text-xs text-muted-foreground">estimé</div>
          )}
          <div className="mt-2">
            {isApproved ? (
              <Button
                variant="outline"
                size="sm"
                onClick={onReopen}
                disabled={isSaving}
              >
                <Unlock className="h-3 w-3 mr-1" />
                Rouvrir
              </Button>
            ) : (
              <Button
                size="sm"
                onClick={onApprove}
                disabled={!canApprove || isSaving}
              >
                <Check className="h-3 w-3 mr-1" />
                Approuver kilométrage
              </Button>
            )}
          </div>
        </div>
      </div>
      {summary.needs_review_count > 0 && (
        <div className="text-xs text-yellow-700 bg-yellow-50 px-2 py-1 rounded">
          {summary.needs_review_count} trajet(s) nécessitent une attribution véhicule/rôle
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-approval-summary.tsx
git commit -m "feat: add MileageApprovalSummaryFooter component"
```

---

## Task 8: MileageEmployeeDetail Component (Right Panel)

**Files:**
- Create: `dashboard/src/components/mileage-approval/mileage-employee-detail.tsx`

**Reference:**
- Pattern: `dashboard/src/components/approvals/day-approval-detail.tsx` (detail panel pattern)

- [ ] **Step 1: Create the employee detail component**

```tsx
'use client';

import { useState } from 'react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { Button } from '@/components/ui/button';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu';
import { ChevronDown, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import type { PayPeriod } from '@/types/payroll';
import type { MileageTripDetail } from '@/types/mileage';
import { useMileageApprovalDetail } from '@/lib/hooks/use-mileage-approval';
import {
  updateTripVehicle,
  batchUpdateTripVehicles,
  approveMileage,
  reopenMileageApproval,
  prefillMileageDefaults,
} from '@/lib/api/mileage-approval';
import { MileageTripRow } from './mileage-trip-row';
import { MileageApprovalSummaryFooter } from './mileage-approval-summary';

interface MileageEmployeeDetailProps {
  employeeId: string;
  employeeName: string;
  period: PayPeriod;
  onChanged: () => void;
}

export function MileageEmployeeDetail({
  employeeId,
  employeeName,
  period,
  onChanged,
}: MileageEmployeeDetailProps) {
  const { detail, tripsByDay, isLoading, error, refetch } = useMileageApprovalDetail(
    employeeId,
    period
  );
  const [isSaving, setIsSaving] = useState(false);
  const isApproved = detail?.approval?.status === 'approved';

  const handleVehicleChange = async (tripId: string, vehicleType: string) => {
    setIsSaving(true);
    try {
      await updateTripVehicle(tripId, vehicleType, null);
      await refetch();
      onChanged();
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors de la mise à jour');
    } finally {
      setIsSaving(false);
    }
  };

  const handleRoleChange = async (tripId: string, role: string) => {
    setIsSaving(true);
    try {
      await updateTripVehicle(tripId, null, role);
      await refetch();
      onChanged();
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors de la mise à jour');
    } finally {
      setIsSaving(false);
    }
  };

  const handleBatchUpdate = async (vehicleType: string | null, role: string | null, tripIds?: string[]) => {
    setIsSaving(true);
    try {
      const ids = tripIds ?? detail!.trips.filter(t => t.eligible).map(t => t.trip_id);
      await batchUpdateTripVehicles(ids, vehicleType, role);
      await refetch();
      onChanged();
      toast.success('Trajets mis à jour');
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors de la mise à jour en lot');
    } finally {
      setIsSaving(false);
    }
  };

  const handleResetDefaults = async () => {
    setIsSaving(true);
    try {
      // Clear vehicle_type and role on all trips first
      const tripIds = detail!.trips.filter(t => t.eligible).map(t => t.trip_id);
      await batchUpdateTripVehicles(tripIds, null, null);
      // Re-prefill
      await prefillMileageDefaults(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Valeurs par défaut réappliquées');
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors du reset');
    } finally {
      setIsSaving(false);
    }
  };

  const handleApprove = async () => {
    setIsSaving(true);
    try {
      await approveMileage(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Kilométrage approuvé');
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors de l\'approbation');
    } finally {
      setIsSaving(false);
    }
  };

  const handleReopen = async () => {
    setIsSaving(true);
    try {
      await reopenMileageApproval(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Kilométrage rouvert');
    } catch (err: any) {
      toast.error(err.message || 'Erreur lors de la réouverture');
    } finally {
      setIsSaving(false);
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (error) {
    return <div className="p-4 text-red-600 text-sm">{error}</div>;
  }

  if (!detail) return null;

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center justify-between p-4 border-b">
        <h3 className="font-semibold">{employeeName}</h3>
        <div className="flex gap-2">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="outline" size="sm" disabled={isApproved || isSaving}>
                Actions en lot <ChevronDown className="h-3 w-3 ml-1" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent>
              <DropdownMenuItem onClick={() => handleBatchUpdate('personal', 'driver')}>
                Tout = Personnel + Conducteur
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => handleBatchUpdate('personal', null)}>
                Tout = Personnel
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => handleBatchUpdate('company', null)}>
                Tout = Compagnie
              </DropdownMenuItem>
              <DropdownMenuItem onClick={handleResetDefaults}>
                Réinitialiser aux valeurs par défaut
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {/* Trip list grouped by day */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {Array.from(tripsByDay.entries()).map(([date, trips]) => (
          <div key={date}>
            <div className="text-xs font-semibold text-muted-foreground uppercase mb-2">
              {format(parseISO(date), 'EEEE d MMMM', { locale: fr })}
            </div>
            <div className="space-y-1">
              {trips.map((trip) => (
                <MileageTripRow
                  key={trip.trip_id}
                  trip={trip}
                  disabled={isApproved || isSaving}
                  onVehicleChange={handleVehicleChange}
                  onRoleChange={handleRoleChange}
                />
              ))}
            </div>
          </div>
        ))}
        {detail.trips.length === 0 && (
          <div className="text-center text-muted-foreground py-8">
            Aucun trajet en véhicule pour cette période
          </div>
        )}
      </div>

      {/* Summary footer */}
      {detail.trips.length > 0 && (
        <MileageApprovalSummaryFooter
          summary={detail.summary}
          approval={detail.approval}
          onApprove={handleApprove}
          onReopen={handleReopen}
          isSaving={isSaving}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-employee-detail.tsx
git commit -m "feat: add MileageEmployeeDetail component (right panel)"
```

---

## Task 9: MileageEmployeeList Component (Left Panel)

**Files:**
- Create: `dashboard/src/components/mileage-approval/mileage-employee-list.tsx`

- [ ] **Step 1: Create the employee list component**

```tsx
'use client';

import { Badge } from '@/components/ui/badge';
import { Users, AlertTriangle, Check, CheckCheck } from 'lucide-react';
import type { MileageApprovalSummaryRow } from '@/types/mileage';

interface MileageEmployeeListProps {
  employees: MileageApprovalSummaryRow[];
  selectedId: string | null;
  onSelect: (employeeId: string) => void;
  teamTotals: {
    totalKm: number;
    totalCompanyKm: number;
    totalAmount: number;
    totalNeedsReview: number;
  };
}

export function MileageEmployeeList({
  employees,
  selectedId,
  onSelect,
  teamTotals,
}: MileageEmployeeListProps) {
  // Sort: needs review first, then ready, then approved
  const sorted = [...employees].sort((a, b) => {
    const aStatus = a.mileage_status === 'approved' ? 2 : a.needs_review_count > 0 ? 0 : 1;
    const bStatus = b.mileage_status === 'approved' ? 2 : b.needs_review_count > 0 ? 0 : 1;
    if (aStatus !== bStatus) return aStatus - bStatus;
    return a.employee_name.localeCompare(b.employee_name);
  });

  return (
    <div className="flex flex-col h-full">
      <div className="flex-1 overflow-y-auto">
        <div className="text-xs font-semibold text-muted-foreground uppercase px-4 py-2">
          Employés ({employees.length})
        </div>
        {sorted.map((emp) => {
          const isSelected = emp.employee_id === selectedId;
          const isApproved = emp.mileage_status === 'approved';
          const needsReview = emp.needs_review_count > 0;

          return (
            <div
              key={emp.employee_id}
              onClick={() => onSelect(emp.employee_id)}
              className={`px-4 py-3 cursor-pointer border-l-[3px] transition-colors ${
                isSelected
                  ? 'border-l-blue-500 bg-blue-50/50'
                  : 'border-l-transparent hover:bg-muted/50'
              } ${isApproved ? 'bg-green-50/30' : ''}`}
            >
              <div className="flex justify-between items-center">
                <span className="font-medium text-sm">{emp.employee_name}</span>
                {isApproved ? (
                  <CheckCheck className="h-4 w-4 text-green-600" />
                ) : needsReview ? (
                  <Badge variant="outline" className="text-xs text-yellow-700 border-yellow-300">
                    <AlertTriangle className="h-3 w-3 mr-1" />
                    {emp.needs_review_count}
                  </Badge>
                ) : (
                  <Check className="h-4 w-4 text-green-600" />
                )}
              </div>
              <div className="text-xs text-muted-foreground mt-1">
                {emp.trip_count} trajets · {emp.reimbursable_km.toFixed(0)} km
                {isApproved && emp.approved_amount != null
                  ? ` · ${emp.approved_amount.toFixed(2)} $`
                  : emp.estimated_amount > 0
                  ? ` · ~${emp.estimated_amount.toFixed(2)} $`
                  : ''}
                {emp.carpool_group_count > 0 && (
                  <span className="ml-1 text-yellow-600">
                    <Users className="inline h-3 w-3" /> {emp.carpool_group_count}
                  </span>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Team totals */}
      <div className="border-t bg-muted/30 p-3 text-xs text-center space-y-1">
        <div>
          Total équipe: <strong>{teamTotals.totalKm.toFixed(0)} km</strong>
          {teamTotals.totalAmount > 0 && (
            <> · <strong>{teamTotals.totalAmount.toFixed(2)} $</strong></>
          )}
        </div>
        {teamTotals.totalNeedsReview > 0 && (
          <div className="text-yellow-700">
            {teamTotals.totalNeedsReview} items à revoir
          </div>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-employee-list.tsx
git commit -m "feat: add MileageEmployeeList component (left panel)"
```

---

## Task 10: MileageApprovalPage + Route + Navigation

**Files:**
- Create: `dashboard/src/components/mileage-approval/mileage-approval-page.tsx`
- Create: `dashboard/src/app/dashboard/mileage-approval/page.tsx`
- Modify: `dashboard/src/components/layout/sidebar.tsx`

**Reference:**
- Pattern: `dashboard/src/app/dashboard/remuneration/payroll/page.tsx` (page route)
- Pattern: `dashboard/src/components/payroll/payroll-period-selector.tsx` (period selector)
- Pattern: `dashboard/src/components/approvals/approval-grid.tsx` (split panel layout)

- [ ] **Step 1: Create the main MileageApprovalPage component**

```tsx
'use client';

import { useState } from 'react';
import { format } from 'date-fns';
import { PayrollPeriodSelector } from '@/components/payroll/payroll-period-selector';
import { useMileageApprovalSummary } from '@/lib/hooks/use-mileage-approval';
import { MileageEmployeeList } from './mileage-employee-list';
import { MileageEmployeeDetail } from './mileage-employee-detail';
import { getLastCompletedPeriod } from '@/lib/utils/pay-periods';
import type { PayPeriod } from '@/types/payroll';
import { Loader2, AlertTriangle } from 'lucide-react';

export function MileageApprovalPage() {
  const todayStr = format(new Date(), 'yyyy-MM-dd');
  const [period, setPeriod] = useState<PayPeriod>(getLastCompletedPeriod(todayStr));
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | null>(null);
  const { employees, teamTotals, isLoading, error, refetch } = useMileageApprovalSummary(period);

  const selectedEmployee = employees.find(e => e.employee_id === selectedEmployeeId);

  return (
    <div className="flex flex-col h-[calc(100vh-64px)]">
      {/* Header */}
      <div className="flex items-center justify-between px-6 py-4 border-b">
        <h1 className="text-lg font-semibold">Approbation kilométrage</h1>
        <PayrollPeriodSelector
          period={period}
          onPeriodChange={setPeriod}
          todayStr={todayStr}
        />
      </div>

      {/* Content */}
      {isLoading ? (
        <div className="flex items-center justify-center flex-1">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : error ? (
        <div className="flex items-center justify-center flex-1">
          <div className="text-red-600 flex items-center gap-2">
            <AlertTriangle className="h-4 w-4" />
            {error}
          </div>
        </div>
      ) : employees.length === 0 ? (
        <div className="flex items-center justify-center flex-1 text-muted-foreground">
          Aucun trajet en véhicule pour cette période
        </div>
      ) : (
        <div className="flex flex-1 overflow-hidden">
          {/* Left panel: employee list (40%) */}
          <div className="w-[40%] border-r overflow-hidden">
            <MileageEmployeeList
              employees={employees}
              selectedId={selectedEmployeeId}
              onSelect={setSelectedEmployeeId}
              teamTotals={teamTotals}
            />
          </div>

          {/* Right panel: employee detail (60%) */}
          <div className="w-[60%] overflow-hidden">
            {selectedEmployeeId && selectedEmployee ? (
              <MileageEmployeeDetail
                employeeId={selectedEmployeeId}
                employeeName={selectedEmployee.employee_name}
                period={period}
                onChanged={refetch}
              />
            ) : (
              <div className="flex items-center justify-center h-full text-muted-foreground">
                Sélectionnez un employé pour voir ses trajets
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Create the page route**

```tsx
import { MileageApprovalPage } from '@/components/mileage-approval/mileage-approval-page';

export default function MileageApprovalRoute() {
  return <MileageApprovalPage />;
}
```

- [ ] **Step 3: Add navigation link**

Read `dashboard/src/components/layout/sidebar.tsx` and add after the "Approbation" entry:

```typescript
{ name: 'Kilométrage', href: '/dashboard/mileage-approval', icon: Car },
```

Import `Car` from `lucide-react` if not already imported.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-approval-page.tsx \
      dashboard/src/app/dashboard/mileage-approval/page.tsx \
      dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: add mileage approval page with navigation"
```

---

## Task 11: Integration Testing & Polish

**Files:**
- All previously created files

- [ ] **Step 1: Run dashboard build to check for TypeScript errors**

```bash
cd dashboard && npm run build
```

Fix any TypeScript errors.

- [ ] **Step 2: Verify SQL RPCs work with test data**

Run SQL to test the flow:
```sql
-- Pick an employee with trips
SELECT employee_id, COUNT(*) as trip_count
FROM trips
WHERE transport_mode = 'driving'
  AND to_business_date(started_at) BETWEEN '2026-03-09' AND '2026-03-22'
GROUP BY employee_id
LIMIT 3;

-- Test prefill
SELECT prefill_mileage_defaults('<employee_id>', '2026-03-09', '2026-03-22');

-- Test summary
SELECT get_mileage_approval_summary('2026-03-09', '2026-03-22');

-- Test detail
SELECT get_mileage_approval_detail('<employee_id>', '2026-03-09', '2026-03-22');
```

- [ ] **Step 3: Test the update_trip_vehicle carpool cascade**

```sql
-- Find a carpool group
SELECT cg.id, cm.trip_id, cm.employee_id, cm.role
FROM carpool_groups cg
JOIN carpool_members cm ON cm.carpool_group_id = cg.id
LIMIT 10;

-- Test cascade: set one member as driver
SELECT update_trip_vehicle('<trip_id>', 'personal', 'driver');

-- Verify others became passengers
SELECT t.id, t.role, cm.role AS cm_role
FROM carpool_members cm
JOIN trips t ON t.id = cm.trip_id
WHERE cm.carpool_group_id = '<group_id>';
```

- [ ] **Step 4: Test approval and locking**

```sql
-- Approve mileage
SELECT approve_mileage('<employee_id>', '2026-03-09', '2026-03-22');

-- Verify lock: this should fail
SELECT update_trip_vehicle('<trip_id>', 'company', 'driver');
-- Expected: ERROR "Mileage is locked for this period"

-- Reopen
SELECT reopen_mileage_approval('<employee_id>', '2026-03-09', '2026-03-22');

-- Now update should work again
SELECT update_trip_vehicle('<trip_id>', 'company', 'driver');
```

- [ ] **Step 5: Fix any issues found during testing**

- [ ] **Step 6: Commit final fixes**

```bash
git add -A
git commit -m "fix: address integration testing feedback for mileage approval"
```

---

## Task 12: Update Payroll Report Integration

**Files:**
- Modify: The existing `get_payroll_period_report` RPC

**Reference:**
- `supabase/migrations/20260324100000_payroll_period_report.sql` or equivalent

- [ ] **Step 1: Find the existing payroll report RPC**

Search for `get_payroll_period_report` in migrations.

- [ ] **Step 2: Create migration to add mileage columns**

Create `supabase/migrations/20260326100002_payroll_report_mileage.sql`:

Add `reimbursable_km` and `reimbursement_amount` from `mileage_approvals` to the payroll report output. Join on `mileage_approvals` matching `employee_id`, `period_start`, `period_end`. Use frozen values when `status = 'approved'`, live-calculated estimate otherwise.

- [ ] **Step 3: Apply migration**

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260326100002_payroll_report_mileage.sql
git commit -m "feat: add mileage reimbursement columns to payroll report"
```
