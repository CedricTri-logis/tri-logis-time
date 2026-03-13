# Timezone Standardization Design

Date: 2026-03-07
Branch: 008-employee-shift-dashboard

## Problem

Mixed timezone handling across SQL functions causes activities to appear on wrong days.
The weekly approval grid uses `started_at::DATE` (UTC) for activities but `(clocked_in_at AT TIME ZONE 'America/Toronto')::DATE` (Eastern) for shifts. Evening activities (after 7pm EST = midnight UTC) get assigned to the next day in the grid but not in the detail view.

## Approach: C1 — Helper functions + config table

Store the business timezone in `app_settings`, expose 3 helper functions. All date conversions go through these helpers. Raw data stays in UTC.

## Section 1: SQL Infrastructure

### Table

```sql
CREATE TABLE app_settings (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  timezone TEXT NOT NULL DEFAULT 'America/Toronto'
);
INSERT INTO app_settings DEFAULT VALUES;
```

### Helper functions

```sql
-- timestamp -> business date
CREATE FUNCTION to_business_date(ts TIMESTAMPTZ) RETURNS DATE AS $$
  SELECT (ts AT TIME ZONE (SELECT timezone FROM app_settings))::DATE;
$$ LANGUAGE sql STABLE;

-- date -> start of business day (TIMESTAMPTZ)
CREATE FUNCTION business_day_start(d DATE) RETURNS TIMESTAMPTZ AS $$
  SELECT (d::TEXT || ' 00:00:00')::TIMESTAMP
         AT TIME ZONE (SELECT timezone FROM app_settings);
$$ LANGUAGE sql STABLE;

-- date -> end of business day (= start of next day)
CREATE FUNCTION business_day_end(d DATE) RETURNS TIMESTAMPTZ AS $$
  SELECT ((d + 1)::TEXT || ' 00:00:00')::TIMESTAMP
         AT TIME ZONE (SELECT timezone FROM app_settings);
$$ LANGUAGE sql STABLE;
```

### Replacement rules

| Before | After |
|--------|-------|
| `(col AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(col)` |
| `col::DATE` (on TIMESTAMPTZ) | `to_business_date(col)` |
| `p_date::TIMESTAMPTZ` | `business_day_start(p_date)` |
| `(p_date + INTERVAL '1 day')::TIMESTAMPTZ` | `business_day_end(p_date)` |

## Section 2: SQL Functions to Fix

### 2a. get_weekly_approval_summary (latest: migration 135)

| CTE | Before | After |
|-----|--------|-------|
| day_shifts | `(s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(s.clocked_in_at)` |
| day_lunch | `(lb.started_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(lb.started_at)` |
| completed_shifts | `(s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(s.clocked_in_at)` |
| shift_real_activities (stops) | `sc.started_at::DATE` | `to_business_date(sc.started_at)` |
| shift_real_activities (trips) | `t.started_at::DATE` | `to_business_date(t.started_at)` |
| shift_real_activities (lunch) | `(lb.started_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(lb.started_at)` |
| live_activity_classification (stops) | `sc.started_at::DATE` | `to_business_date(sc.started_at)` |
| live_activity_classification (trips) | `t.started_at::DATE` | `to_business_date(t.started_at)` |
| live_activity_classification (gaps) | `g.gap_started_at::DATE` | `to_business_date(g.gap_started_at)` |

### 2b. get_day_approval_detail (latest: migration 138)

| Section | Before | After |
|---------|--------|-------|
| Active shift check | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| Total shift minutes | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| Lunch minutes | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| shift_boundaries | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| Stops filter | `>= p_date::TIMESTAMPTZ` / `< (p_date+1)::TIMESTAMPTZ` | `>= business_day_start(p_date)` / `< business_day_end(p_date)` |
| Trips filter | same | same |
| Clock in filter | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| Clock out filter | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |
| Lunch breaks filter | `AT TIME ZONE 'America/Toronto'` | `to_business_date()` |

### 2c. detect_carpools (latest: migration 077)

| Before | After |
|--------|-------|
| `WHERE started_at::DATE = p_date` | `WHERE to_business_date(started_at) = p_date` |

### 2d. get_mileage_summary (latest: migration 068)

| Before | After |
|--------|-------|
| `t.started_at::DATE` (x3, passed to has_active_vehicle_period) | `to_business_date(t.started_at)` |

### 2e. get_cleaning_dashboard (latest: migration 016)

| Before | After |
|--------|-------|
| `cs.started_at::DATE` (x6 occurrences) | `to_business_date(cs.started_at)` |

## Section 3: Dashboard TypeScript

### New helper: `dashboard/src/lib/utils/date-utils.ts`

```typescript
export function toLocalDateString(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

export function parseLocalDate(dateStr: string): Date {
  return new Date(dateStr + 'T12:00:00');
}

export function addDays(dateStr: string, days: number): string {
  const d = parseLocalDate(dateStr);
  d.setDate(d.getDate() + days);
  return toLocalDateString(d);
}

export function getMonday(dateStr?: string): string {
  const d = dateStr ? parseLocalDate(dateStr) : new Date();
  const day = d.getDay();
  d.setDate(d.getDate() - day + (day === 0 ? -6 : 1));
  return toLocalDateString(d);
}
```

### Files to fix

| File | Change |
|------|--------|
| approval-grid.tsx | Replace local getMonday/formatDateISO with date-utils imports |
| types/dashboard.ts | getDateRangeDates() returns strings, uses toLocalDateString |
| lib/validations/reports.ts | resolveDateRange() uses toLocalDateString and addDays |
| lib/hooks/use-cleaning-sessions.ts | Replace .toISOString().split('T')[0] with toLocalDateString() |
| components/cleaning/cleaning-filters.tsx | formatDateInput() -> toLocalDateString() |
| components/mileage/stationary-clusters-tab.tsx | getDefaultDateFrom() -> addDays(toLocalDateString(new Date()), -30) |
| components/mileage/carpooling-tab.tsx | Same pattern + handleRedetect date loop |
| components/mileage/activity-tab.tsx | Replace local formatDateISO with import |
| components/mileage/vehicle-periods-tab.tsx | Replace .toISOString().split('T')[0] |
| app/dashboard/teams/page.tsx | getDateRangeDates() returns strings -> pass to RPC directly |

### Not touched (display-only, safe)

day-approval-detail.tsx, cleaning-sessions-table.tsx, stationary-clusters-map.tsx

## Section 4: Flutter

### Files to fix

| File | Lines | Fix |
|------|-------|-----|
| history_filter_provider.dart | 88-122 | Store bounds as YYYY-MM-DD strings |
| shift_history_filter.dart | 116-120 | Send date-only strings for p_start_date/p_end_date |
| history_service.dart | 131-135, 174-178 | Send date-only strings |
| dashboard_service.dart | 157-158, 176-177 | Send date-only strings |

### Not touched (already safe)

| File | Why |
|------|-----|
| trip_service.dart 123-125 | TIMESTAMPTZ vs TIMESTAMPTZ, UTC boundaries correct |
| trip_service.dart 375-396 | Compares DATE columns, local date correct for Montreal |
| mileage_summary_provider.dart | Already sends date-only strings |
| mileage_local_db.dart | Local SQLCipher cache |
| All toJson()/fromJson() | Raw UTC storage, correct |
