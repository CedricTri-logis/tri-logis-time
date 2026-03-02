-- Migration 103: Backfill effective_location_type for existing clusters
-- Sets effective type based on current building links, home associations, and office flags.
-- Only affects clusters with a matched location.

UPDATE stationary_clusters sc
SET effective_location_type = CASE
  WHEN EXISTS (
    SELECT 1 FROM cleaning_sessions cs
    JOIN studios s ON s.id = cs.studio_id
    JOIN buildings b ON b.id = s.building_id
    WHERE b.location_id = sc.matched_location_id
      AND cs.employee_id = sc.employee_id
      AND cs.shift_id = sc.shift_id
      AND cs.started_at < sc.ended_at
      AND (cs.completed_at > sc.started_at OR cs.completed_at IS NULL)
  ) THEN 'building'
  WHEN EXISTS (
    SELECT 1 FROM maintenance_sessions ms
    JOIN property_buildings pb ON pb.id = ms.building_id
    WHERE pb.location_id = sc.matched_location_id
      AND ms.employee_id = sc.employee_id
      AND ms.shift_id = sc.shift_id
      AND ms.started_at < sc.ended_at
      AND (ms.completed_at > sc.started_at OR ms.completed_at IS NULL)
  ) THEN 'building'
  WHEN EXISTS (
    SELECT 1 FROM locations l
    JOIN employee_home_locations ehl ON ehl.location_id = l.id
    WHERE l.id = sc.matched_location_id
      AND l.is_employee_home = true
      AND ehl.employee_id = sc.employee_id
  ) THEN 'home'
  WHEN EXISTS (
    SELECT 1 FROM locations l
    WHERE l.id = sc.matched_location_id
      AND l.is_also_office = true
  ) THEN 'office'
  ELSE (
    SELECT l.location_type::TEXT FROM locations l
    WHERE l.id = sc.matched_location_id
  )
END
WHERE sc.matched_location_id IS NOT NULL
  AND sc.effective_location_type IS NULL;
