# RPC Contracts: Mileage Tracking

## detect_trips

Analyzes GPS points for a shift and inserts detected vehicle trips. Idempotent: deletes existing trips for the shift before re-detecting.

```sql
CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS TABLE (
    trip_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    start_latitude DECIMAL(10, 8),
    start_longitude DECIMAL(11, 8),
    end_latitude DECIMAL(10, 8),
    end_longitude DECIMAL(11, 8),
    distance_km DECIMAL(8, 3),
    duration_minutes INTEGER,
    confidence_score DECIMAL(3, 2),
    gps_point_count INTEGER
) AS $$
-- Algorithm:
-- 1. Fetch gps_points for shift, ordered by captured_at
-- 2. Filter outliers (accuracy > 200m, speed > 200 km/h)
-- 3. Calculate speed between consecutive points
-- 4. Segment into trips (vehicle speed > 15 km/h, stationary gap > 3 min)
-- 5. Apply minimum distance filter (500m)
-- 6. Apply 1.3x road distance correction factor
-- 7. Delete existing trips for shift (idempotent)
-- 8. Insert new trips + trip_gps_points junction records
-- 9. Return detected trips
$$;
```

**Caller**: Mobile (clock-out flow), Dashboard (on-demand), Sync service (after GPS sync)
**Auth**: Authenticated user must own the shift or be a supervisor of the shift's employee
**Error cases**:
- Shift not found → raises exception
- Shift still active → raises exception (must be completed first)
- No GPS points → returns empty set (not an error)

---

## get_mileage_summary

Returns aggregated mileage statistics for an employee over a date range, including CRA tiered reimbursement calculation.

```sql
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
    ytd_business_km DECIMAL(10, 3)  -- Year-to-date for tier calculation
) AS $$
-- Algorithm:
-- 1. Sum trips for employee in date range
-- 2. Separate business vs personal
-- 3. Calculate YTD business km (Jan 1 to period_end) for tier threshold
-- 4. Look up current reimbursement_rate
-- 5. Apply tiered rate: first 5000 km at rate_per_km, remainder at rate_after_threshold
-- 6. Return aggregated summary
$$;
```

**Caller**: Mobile (mileage screen), Dashboard (team overview)
**Auth**: Employee can query own data; managers can query supervised employees
**Note**: Reimbursement calculation uses the rate effective at `p_period_end`

---

## update_trip_classification

Toggles a trip between 'business' and 'personal'. Only the trip's employee can do this.

```sql
-- This is a simple UPDATE via Supabase client, no custom RPC needed.
-- RLS policy ensures only the trip's employee can update classification.

-- Mobile (Dart):
await supabase
  .from('trips')
  .update({'classification': 'personal'})
  .eq('id', tripId);

-- Dashboard (TypeScript):
await supabase
  .from('trips')
  .update({ classification: 'personal' })
  .eq('id', tripId);
```

**Auth**: RLS policy `"Employees can update own trip classification"` on `trips` table
**Constraint**: Only `classification` column is updatable by employees (RLS WITH CHECK)

---

## get_team_mileage_summary

Returns mileage summaries for all employees supervised by the requesting manager.

```sql
CREATE OR REPLACE FUNCTION get_team_mileage_summary(
    p_period_start DATE,
    p_period_end DATE
)
RETURNS TABLE (
    employee_id UUID,
    employee_name TEXT,
    total_distance_km DECIMAL(10, 3),
    business_distance_km DECIMAL(10, 3),
    trip_count INTEGER,
    estimated_reimbursement DECIMAL(10, 2),
    avg_daily_km DECIMAL(8, 3)
) AS $$
-- Algorithm:
-- 1. Get employees supervised by auth.uid() from employee_supervisors
-- 2. For each employee, aggregate trips in date range
-- 3. Calculate reimbursement using current rate
-- 4. Return one row per employee, sorted by total_distance_km DESC
$$;
```

**Caller**: Dashboard (team mileage page)
**Auth**: Only managers see their supervised employees (enforced in function via `auth.uid()`)

---

## get_current_reimbursement_rate

Returns the currently active reimbursement rate.

```sql
-- Simple SELECT via Supabase client, no custom RPC needed.

-- Mobile (Dart):
final rate = await supabase
  .from('reimbursement_rates')
  .select()
  .lte('effective_from', DateTime.now().toIso8601String())
  .or('effective_to.is.null,effective_to.gte.${DateTime.now().toIso8601String()}')
  .order('effective_from', ascending: false)
  .limit(1)
  .single();

-- Dashboard (TypeScript):
const { data: rate } = await supabase
  .from('reimbursement_rates')
  .select()
  .lte('effective_from', new Date().toISOString())
  .or(`effective_to.is.null,effective_to.gte.${new Date().toISOString()}`)
  .order('effective_from', { ascending: false })
  .limit(1)
  .single();
```

**Auth**: All authenticated users can read rates (RLS: SELECT for authenticated)

---

## upsert_reimbursement_rate (Admin only)

Creates or updates a reimbursement rate. Automatically sets `effective_to` on the previous rate.

```sql
CREATE OR REPLACE FUNCTION upsert_reimbursement_rate(
    p_rate_per_km DECIMAL(5, 4),
    p_threshold_km INTEGER DEFAULT NULL,
    p_rate_after_threshold DECIMAL(5, 4) DEFAULT NULL,
    p_effective_from DATE DEFAULT CURRENT_DATE,
    p_rate_source TEXT DEFAULT 'custom',
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID AS $$
-- Algorithm:
-- 1. Verify caller is admin (check employee_profiles.role)
-- 2. Set effective_to on currently active rate to p_effective_from - 1 day
-- 3. Insert new rate with p_effective_from and effective_to = NULL
-- 4. Return new rate id
$$;
```

**Caller**: Dashboard (admin rate config dialog)
**Auth**: Admin role required (checked inside function)
