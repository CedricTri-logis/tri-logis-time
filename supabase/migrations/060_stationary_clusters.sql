-- =============================================================================
-- Migration 060: Stationary Clusters table + FK columns on gps_points & trips
-- =============================================================================
-- Groups of stationary GPS points with accuracy-weighted centroids.
-- Used to identify stops during shifts and link them to trip start/end.
--
-- 1. New table: stationary_clusters
-- 2. Indexes on stationary_clusters
-- 3. New column on gps_points: stationary_cluster_id (FK)
-- 4. New columns on trips: start_cluster_id, end_cluster_id (FK)
-- 5. RLS policies on stationary_clusters
-- =============================================================================

-- =============================================================================
-- 1. New table: stationary_clusters
-- =============================================================================
CREATE TABLE stationary_clusters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    centroid_latitude DECIMAL(10, 8) NOT NULL,
    centroid_longitude DECIMAL(11, 8) NOT NULL,
    centroid_accuracy DECIMAL(6, 2),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    duration_seconds INTEGER NOT NULL,
    gps_point_count INTEGER NOT NULL DEFAULT 0,
    matched_location_id UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 2. Indexes on stationary_clusters
-- =============================================================================
CREATE INDEX idx_stationary_clusters_shift ON stationary_clusters(shift_id);
CREATE INDEX idx_stationary_clusters_employee_time ON stationary_clusters(employee_id, started_at DESC);
CREATE INDEX idx_stationary_clusters_location ON stationary_clusters(matched_location_id) WHERE matched_location_id IS NOT NULL;

-- =============================================================================
-- 3. New column on gps_points: stationary_cluster_id
-- =============================================================================
ALTER TABLE gps_points ADD COLUMN stationary_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;
CREATE INDEX idx_gps_points_cluster ON gps_points(stationary_cluster_id) WHERE stationary_cluster_id IS NOT NULL;

-- =============================================================================
-- 4. New columns on trips: start_cluster_id, end_cluster_id
-- =============================================================================
ALTER TABLE trips ADD COLUMN start_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;
ALTER TABLE trips ADD COLUMN end_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;

-- =============================================================================
-- 5. RLS policies on stationary_clusters
-- =============================================================================
ALTER TABLE stationary_clusters ENABLE ROW LEVEL SECURITY;

-- Admins/super_admins can view all clusters
CREATE POLICY "Admins can view all stationary clusters"
ON stationary_clusters FOR SELECT TO authenticated
USING (
    public.is_admin_or_super_admin((SELECT auth.uid()))
);

-- Employees can view their own clusters
CREATE POLICY "Employees can view own stationary clusters"
ON stationary_clusters FOR SELECT TO authenticated
USING (
    employee_id = (SELECT auth.uid())
);

-- Managers can view supervised employee clusters
CREATE POLICY "Managers can view supervised employee stationary clusters"
ON stationary_clusters FOR SELECT TO authenticated
USING (
    employee_id IN (
        SELECT es.employee_id FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
