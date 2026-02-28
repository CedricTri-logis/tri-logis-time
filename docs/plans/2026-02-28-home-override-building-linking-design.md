# Home Override & Building-Location Linking Design

**Date:** 2026-02-28
**Status:** Approved

## Problem

Three independent systems exist without any links between them:

1. **GPS Geofences** (`locations` table) — 101 active locations with PostGIS coordinates and types (building, office, home, etc.)
2. **Cleaning System** (`buildings` + `studios`) — 10 buildings with brand names (Le Cardinal, Le Citadin, etc.)
3. **Property Management** (`property_buildings` + `apartments`) — 77 buildings with address-based names

Key issues:
- Employees who live in company buildings have their clusters typed as `building` instead of `home`
- Employees at the office (Le Chic-urbain / 151-159 Principale) always show `office` even when doing cleaning/maintenance
- No way to associate a "home" location with specific employees
- No link between cleaning/maintenance buildings and GPS geofences

## Design

### 1. Schema Changes

#### New columns on `locations`
- `is_employee_home` BOOLEAN DEFAULT false — toggle "this location is also an employee's home"
- `is_also_office` BOOLEAN DEFAULT false — toggle "this location is also an office"

#### New column on `buildings` (cleaning)
- `location_id` UUID FK → locations (nullable) — links cleaning building to its geofence

#### New column on `property_buildings` (maintenance)
- `location_id` UUID FK → locations (nullable) — links property building to its geofence

#### New table: `employee_home_locations`
- `id` UUID PK DEFAULT gen_random_uuid()
- `employee_id` UUID FK → employee_profiles (ON DELETE CASCADE)
- `location_id` UUID FK → locations (ON DELETE CASCADE)
- `created_at` TIMESTAMPTZ DEFAULT now()
- UNIQUE(employee_id, location_id)
- An employee can have multiple home locations

#### New column on `stationary_clusters`
- `effective_location_type` TEXT (nullable) — dynamically computed type

### 2. Effective Location Type Logic

Computed in `detect_trips()` after cluster-to-location matching. Priority order:

1. **Session override → `building`**: If employee has an active cleaning_session or maintenance_session at a building linked to this location during the cluster's time window → effective type = `building`
2. **Home association → `home`**: If `location.is_employee_home = true` AND employee_id exists in `employee_home_locations` for this location → effective type = `home`
3. **Office flag → `office`**: If `location.is_also_office = true` → effective type = `office`
4. **Default**: Use `location.location_type` as-is

### 3. Override Detection SQL (pseudocode)

```sql
-- For each cluster C matched to location L:

-- Step 1: Check for cleaning session overlap
SELECT EXISTS (
  SELECT 1 FROM cleaning_sessions cs
  JOIN studios s ON s.id = cs.studio_id
  JOIN buildings b ON b.id = s.building_id
  WHERE b.location_id = L.id
    AND cs.employee_id = v_employee_id
    AND cs.shift_id = v_shift_id
    AND cs.started_at < C.ended_at
    AND (cs.completed_at > C.started_at OR cs.completed_at IS NULL)
) INTO v_has_cleaning;

-- Step 2: Check for maintenance session overlap
SELECT EXISTS (
  SELECT 1 FROM maintenance_sessions ms
  JOIN property_buildings pb ON pb.id = ms.building_id
  WHERE pb.location_id = L.id
    AND ms.employee_id = v_employee_id
    AND ms.shift_id = v_shift_id
    AND ms.started_at < C.ended_at
    AND (ms.completed_at > C.started_at OR ms.completed_at IS NULL)
) INTO v_has_maintenance;

-- Step 3: Determine effective type
IF v_has_cleaning OR v_has_maintenance THEN
  v_effective_type := 'building';
ELSIF L.is_employee_home AND EXISTS (
  SELECT 1 FROM employee_home_locations ehl
  WHERE ehl.location_id = L.id AND ehl.employee_id = v_employee_id
) THEN
  v_effective_type := 'home';
ELSIF L.is_also_office THEN
  v_effective_type := 'office';
ELSE
  v_effective_type := L.location_type;
END IF;
```

### 4. Dashboard UI Changes

#### Location edit page (`/dashboard/locations/[id]`)
Two new sections:

**"Home d'employe(s)"**
- Toggle switch for `is_employee_home`
- When ON: multi-select employee picker
- Manages `employee_home_locations` rows
- Note: "Les clusters de ces employes seront affiches comme 'Maison' sauf session menage/entretien active"

**"Aussi un bureau"**
- Toggle switch for `is_also_office`
- Note: "Les clusters seront affiches comme 'Bureau' sauf session menage/entretien active"

**"Building lie"**
- Dropdown to associate a cleaning building (from `buildings` table)
- Dropdown to associate a property building (from `property_buildings` table)
- Read-only display showing linked building name

#### Employee detail page
- New section "Locations maison" listing associated home locations

### 5. Data Backfill

#### Property Buildings → Locations (72 automatic matches by name)
Names match exactly between `property_buildings.name` and `locations.name`.

5 property_buildings without location match (out of scope):
- 10_Olivier (Sallabery-de-valleyfield)
- 100_Mgr-Tessier-O
- 103-105_Dallaire
- 21_Lausanne (Montcalm)
- 29_Perreault-E

#### Cleaning Buildings → Locations (via short_term.building_studio_mapping)

| Cleaning Building | Location Name |
|---|---|
| Le Cardinal | 254-258_Cardinal-Begin-E |
| Le Central | 22-28_Gamble-O |
| Le Centre-Ville | 14-20_Perreault-E |
| Le Chambreur | 110-114_Mgr-Tessier-O |
| Le Chic-urbain | 151-159_Principale (office) |
| Le Cinq Etoiles | 500_Boutour |
| Le Citadin | 45_Perreault-E |
| Le Contemporain | 296-300_Principale |
| Le Convivial | 62-66_Perreault-E |
| Le Court-toit | 96_Horne |

#### Office flag
- `151-159_Principale` (Le Chic-urbain) → set `is_also_office = true`

### 6. Flutter Changes (minimal)

- Add `effectiveLocationType` field to `StationaryCluster` model
- Activity screen uses `effectiveLocationType ?? locationType` for icons/labels
- No changes to cleaning/maintenance scanning flow

### 7. Propagation

`get_employee_activity()` RPC returns `effective_location_type` for stops. This propagates to:
- Flutter app (activity screen)
- Dashboard shift monitoring
- Dashboard GPS visualization

### 8. RLS

#### `employee_home_locations`
- SELECT: Admin/super_admin OR supervisor of employee
- INSERT/UPDATE/DELETE: Admin/super_admin only

### 9. Backward Compatibility

- All new columns default to false/null — existing behavior unchanged
- `effective_location_type` is nullable — when null, use `location_type`
- No changes to existing location types or matching logic
- Override only activates when `is_employee_home` or `is_also_office` is explicitly set to true

### 10. Migrations

| # | Name | Description |
|---|---|---|
| 093 | home_override_schema | `employee_home_locations` table, `is_employee_home`/`is_also_office` on locations, `location_id` FK on buildings + property_buildings, `effective_location_type` on stationary_clusters |
| 094 | backfill_building_location_links | Auto-link property_buildings and cleaning buildings to locations by name match |
| 095 | detect_trips_effective_type | Update detect_trips with effective location type calculation |
