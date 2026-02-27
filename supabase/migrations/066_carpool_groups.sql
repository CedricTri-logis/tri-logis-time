-- Migration 066: Carpool groups and members
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
