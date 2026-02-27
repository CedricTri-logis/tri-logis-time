# Mileage Enhancements: Carpooling Detection, Vehicle Periods & Trip Classification

**Date:** 2026-02-27
**Status:** Approved
**Branch:** TBD (new feature branch)

## Problem

The current mileage tracking system treats all driving+business trips as reimbursable. Three gaps exist:

1. **Carpooling**: When two employees ride together, both get reimbursed. Only the driver (vehicle owner) should be.
2. **Company vehicles**: Employees using company-provided vehicles shouldn't receive mileage reimbursement.
3. **Vehicle ownership tracking**: No way to track which employees have personal vehicles (and when).

## Design

### 1. Data Model

#### Table: `employee_vehicle_periods`

Tracks when an employee has access to a personal or company vehicle. Period-based (not a permanent flag) because vehicle access changes over time.

```sql
CREATE TABLE employee_vehicle_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    vehicle_type TEXT NOT NULL CHECK (vehicle_type IN ('personal', 'company')),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing period
    notes TEXT,     -- e.g., "Ford Escape 2022", "Camion Tri-Logis #12"
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

- Non-overlapping constraint per employee_id + vehicle_type
- Admin/super_admin only (managed from dashboard)
- An employee can have both types simultaneously (personal car + company truck)

#### Table: `carpool_groups`

Represents a detected group of employees who traveled together.

```sql
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
```

- `review_needed = true` when 0 or 2+ members have active personal vehicle periods
- `status`: auto_detected → confirmed/dismissed by admin
- `driver_employee_id`: set automatically when exactly 1 member has personal vehicle

#### Table: `carpool_members`

Links trips to carpool groups with assigned roles.

```sql
CREATE TABLE carpool_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carpool_group_id UUID NOT NULL REFERENCES carpool_groups(id) ON DELETE CASCADE,
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    role TEXT NOT NULL DEFAULT 'unassigned'
        CHECK (role IN ('driver', 'passenger', 'unassigned')),
    UNIQUE(carpool_group_id, trip_id)
);
```

**No columns added to `trips` table** — the relationship goes through `carpool_members` to avoid touching the most-used table.

### 2. Carpooling Detection Algorithm

#### RPC: `detect_carpools(p_date DATE)`

**Trigger:** Called after `detect_trips` completes for a shift. Can also be triggered manually from the dashboard.

**Algorithm:**

1. Fetch all `driving` trips for `p_date`
2. Compare each pair of trips (different employees):
   - Haversine distance between starts < **200m**
   - Haversine distance between ends < **200m**
   - Temporal overlap > **80%** of the shorter trip's duration
3. Group linked trips transitively (if A~B and B~C → group {A,B,C})
4. For each group, check `employee_vehicle_periods` active on `p_date`:
   - **Exactly 1** with `personal` active → auto-assign as driver, others = passengers
   - **0** with `personal` active → all `unassigned`, `review_needed = true`
   - **2+** with `personal` active → first alphabetically = driver (default), `review_needed = true`
5. **Idempotent:** deletes existing carpool_groups for `p_date` before re-creating

### 3. Updated Reimbursement Logic

```sql
-- In get_mileage_summary:
Reimbursable =
    classification = 'business'
    AND transport_mode = 'driving'
    AND NOT EXISTS (active company_vehicle period for employee on trip date)
    AND (NOT in any carpool_group OR carpool role = 'driver')
```

### 4. Flutter App UI (Employee View)

#### Trip Card Badges
- **Existing:** `Business` (blue) / `Personal` (grey) — unchanged, still tappable
- **New:** `Passager` (orange, person icon) — when employee is a carpool passenger
- **New:** `Véh. entreprise` (purple, business icon) — when company_vehicle period active
- Passenger badge shows driver name: "Passager · Avec Jean Dupont"

#### Trip Detail Screen
- New "Covoiturage" section when trip belongs to a carpool group
- Lists all group members with their roles (driver/passenger)
- If role = passenger: "0 km remboursé — vous étiez passager"

#### Summary Card
- Existing business_distance_km and estimated_reimbursement already exclude non-reimbursable trips (server-side logic)
- Optional: add "Trips en covoiturage: N" line

#### No Vehicle Management UI for Employees
Employees don't manage their vehicle periods. Admins configure them from the dashboard. Employees only see the effect (badges on their trips).

### 5. Dashboard UI (Admin View)

#### New Tab: Vehicle Management
- Employee list with active vehicle periods
- "Add period" button → form: employee, type (personal/company), start date, end date (optional), notes
- Edit/delete existing periods
- Filters: by vehicle type, by employee, active/expired periods

#### New Tab: Carpooling
- List of detected carpool groups
- Filters: by date, by status (auto_detected/confirmed/dismissed), review_needed
- Each group shows: date, members (names), roles (driver/passenger/unassigned)
- Actions: Confirm, Dismiss, Change driver
- Red badge "À réviser" for groups with `review_needed = true`
- "Re-detect" button to rerun detection on a date range

#### Existing Trips Tab — Additions
- New "Covoiturage" column with badge (Conducteur/Passager/—)
- New filter: "Covoiturage" (yes/no/all)
- New "Véhicule" column: Personnel/Entreprise/— based on active periods

### 6. RLS Policies

| Table | SELECT | INSERT/UPDATE/DELETE |
|-------|--------|---------------------|
| employee_vehicle_periods | Admin/super_admin + employee sees own | Admin/super_admin only |
| carpool_groups | Admin/super_admin + members see own groups | Admin/super_admin only |
| carpool_members | Admin/super_admin + employee sees own membership | Admin/super_admin only |

### 7. Migration Sequence

1. `060_employee_vehicle_periods` — table + RLS + indexes
2. `061_carpool_groups` — tables (carpool_groups + carpool_members) + RLS + indexes
3. `062_detect_carpools_rpc` — detection function
4. `063_update_mileage_summary` — update get_mileage_summary to account for carpooling + company vehicles

## Not In Scope

- Employee self-service vehicle period management (admin only)
- Historical backfill of carpool detection (runs on new data only, unless manually triggered)
- Notifications to employees when detected as passenger
- Mobile offline support for carpool data (read-only, fetched on sync)
