-- Migration 099: Home override schema
-- Adds employee_home_locations table, is_employee_home/is_also_office flags on locations,
-- location_id FK on buildings and property_buildings, effective_location_type on stationary_clusters

-- 1. New columns on locations
ALTER TABLE locations ADD COLUMN is_employee_home BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE locations ADD COLUMN is_also_office BOOLEAN NOT NULL DEFAULT false;

-- 2. New FK on buildings (cleaning)
ALTER TABLE buildings ADD COLUMN location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- 3. New FK on property_buildings (maintenance)
ALTER TABLE property_buildings ADD COLUMN location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- 4. New column on stationary_clusters
ALTER TABLE stationary_clusters ADD COLUMN effective_location_type TEXT;

-- 5. New table: employee_home_locations
CREATE TABLE employee_home_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, location_id)
);

-- Indexes
CREATE INDEX idx_employee_home_locations_employee ON employee_home_locations(employee_id);
CREATE INDEX idx_employee_home_locations_location ON employee_home_locations(location_id);
CREATE INDEX idx_buildings_location ON buildings(location_id);
CREATE INDEX idx_property_buildings_location ON property_buildings(location_id);

-- 6. RLS on employee_home_locations
ALTER TABLE employee_home_locations ENABLE ROW LEVEL SECURITY;

-- SELECT: admin/super_admin or supervisor of employee
CREATE POLICY employee_home_locations_select ON employee_home_locations
  FOR SELECT USING (
    is_admin_or_super_admin(auth.uid())
    OR employee_id IN (
      SELECT es.employee_id FROM employee_supervisors es
      WHERE es.manager_id = auth.uid()
    )
  );

-- INSERT/UPDATE/DELETE: admin/super_admin only
CREATE POLICY employee_home_locations_insert ON employee_home_locations
  FOR INSERT WITH CHECK (is_admin_or_super_admin(auth.uid()));

CREATE POLICY employee_home_locations_update ON employee_home_locations
  FOR UPDATE USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY employee_home_locations_delete ON employee_home_locations
  FOR DELETE USING (is_admin_or_super_admin(auth.uid()));
