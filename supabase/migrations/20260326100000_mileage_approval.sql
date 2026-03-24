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
      WHERE es.manager_id = auth.uid()
        AND es.employee_id = mileage_approvals.employee_id
    )
  );

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

-- 5. Update CRA rates from 2025 ($0.72/$0.66) to 2026 ($0.73/$0.67)
UPDATE reimbursement_rates
SET rate_per_km = 0.73,
    rate_after_threshold = 0.67,
    effective_from = '2026-01-01'
WHERE threshold_km = 5000
  AND rate_per_km = 0.72;
