# Timezone Standardization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Standardize all date/timezone handling to use configurable business timezone via helper functions, fixing bugs where evening activities appear on wrong days.

**Architecture:** Create `app_settings` table + 3 SQL helper functions (`to_business_date`, `business_day_start`, `business_day_end`). Replace all hardcoded `AT TIME ZONE 'America/Toronto'` and bare `::DATE` casts in SQL. Fix dashboard and Flutter to send timezone-safe date strings.

**Tech Stack:** PostgreSQL (Supabase), TypeScript (Next.js dashboard), Dart (Flutter app)

**Design doc:** `docs/plans/2026-03-07-timezone-standardization-design.md`

---

### Task 1: SQL Migration — Infrastructure + All Function Fixes

**Files:**
- Create: `supabase/migrations/139_timezone_standardization.sql`

This is a single migration that creates the infrastructure and rewrites all affected functions.

**Step 1: Create the migration file**

The migration has these sections in order:

**Section A — Infrastructure:**

```sql
-- =============================================================================
-- 139: Timezone standardization
-- =============================================================================
-- Creates app_settings table with configurable business timezone and 3 helper
-- functions. Rewrites all SQL functions to use helpers instead of hardcoded
-- timezone or bare UTC ::DATE casts.
-- =============================================================================

-- 1. Config table (single-row)
CREATE TABLE IF NOT EXISTS app_settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    timezone TEXT NOT NULL DEFAULT 'America/Toronto'
);
INSERT INTO app_settings (id, timezone) VALUES (1, 'America/Toronto')
ON CONFLICT (id) DO NOTHING;

-- 2. Helper: TIMESTAMPTZ -> business DATE
CREATE OR REPLACE FUNCTION to_business_date(ts TIMESTAMPTZ)
RETURNS DATE AS $$
    SELECT (ts AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1))::DATE;
$$ LANGUAGE sql STABLE;

-- 3. Helper: DATE -> start of business day as TIMESTAMPTZ
CREATE OR REPLACE FUNCTION business_day_start(d DATE)
RETURNS TIMESTAMPTZ AS $$
    SELECT (d::TEXT || ' 00:00:00')::TIMESTAMP
           AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1);
$$ LANGUAGE sql STABLE;

-- 4. Helper: DATE -> end of business day (= start of next day) as TIMESTAMPTZ
CREATE OR REPLACE FUNCTION business_day_end(d DATE)
RETURNS TIMESTAMPTZ AS $$
    SELECT ((d + 1)::TEXT || ' 00:00:00')::TIMESTAMP
           AT TIME ZONE (SELECT timezone FROM app_settings WHERE id = 1);
$$ LANGUAGE sql STABLE;
```

**Section B — Fix `get_weekly_approval_summary`:**

Base: migration 133 (currently deployed, has `live_activity_classification` + `lunch_minutes`).

Apply these find-and-replace operations to the full function source from migration 133:

| Find | Replace | Occurrences |
|------|---------|-------------|
| `(s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(s.clocked_in_at)` | 3 (day_shifts SELECT, WHERE, GROUP BY) |
| `(lb.started_at AT TIME ZONE 'America/Toronto')::DATE` | `to_business_date(lb.started_at)` | 3 (day_lunch SELECT, WHERE, GROUP BY + shift_real_activities WHERE) |
| `sc.started_at::DATE` | `to_business_date(sc.started_at)` | 2 (shift_real_activities WHERE, live_activity_classification SELECT+WHERE) |
| `t.started_at::DATE` | `to_business_date(t.started_at)` | 2 (shift_real_activities WHERE, live_activity_classification) |
| `g.gap_started_at::DATE` | `to_business_date(g.gap_started_at)` | 2 (live_activity_classification for gaps) |

Also fix the subquery in migration 135's `unmatched_stop_count` pattern if present:
| `AND sc.started_at::DATE = ds.shift_date` | `AND to_business_date(sc.started_at) = ds.shift_date` | 1 |

**Section C — Fix `get_day_approval_detail`:**

Base: migration 138 (latest).

| Find | Replace | Lines |
|------|---------|-------|
| `(clocked_in_at AT TIME ZONE 'America/Toronto')::DATE = p_date` | `to_business_date(clocked_in_at) = p_date` | 30, 51, 72, 266, 328 |
| `(lb.started_at AT TIME ZONE 'America/Toronto')::DATE = p_date` | `to_business_date(lb.started_at) = p_date` | 62, 363 |
| `sc.started_at >= p_date::TIMESTAMPTZ` | `sc.started_at >= business_day_start(p_date)` | 126 |
| `sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ` | `sc.started_at < business_day_end(p_date)` | 127 |
| `t.started_at >= p_date::TIMESTAMPTZ` | `t.started_at >= business_day_start(p_date)` | 204 |
| `t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ` | `t.started_at < business_day_end(p_date)` | 205 |

**Section D — Fix `detect_carpools`:**

Base: migration 077.

Single change in the CREATE TEMP TABLE statement:
| `WHERE started_at::DATE = p_date` | `WHERE to_business_date(started_at) = p_date` | line 54 |

**Section E — Fix `get_mileage_summary`:**

Base: migration 068.

| Find | Replace | Lines |
|------|---------|-------|
| `t.started_at::DATE` (passed to has_active_vehicle_period) | `to_business_date(t.started_at)` | 49, 62, 80 |
| `t.started_at >= p_period_start::TIMESTAMPTZ` | `t.started_at >= business_day_start(p_period_start)` | 73 |
| `t.started_at < (p_period_end + 1)::TIMESTAMPTZ` | `t.started_at < business_day_end(p_period_end)` | 74 |
| `(v_period_year \|\| '-01-01')::TIMESTAMPTZ` | `business_day_start((v_period_year \|\| '-01-01')::DATE)` | 91 |
| `t.started_at < (p_period_end + 1)::TIMESTAMPTZ` (YTD) | `t.started_at < business_day_end(p_period_end)` | 92 |

**Section F — Fix `get_cleaning_dashboard`:**

Base: migration 016 (function starting at line 448).

| Find | Replace | Lines |
|------|---------|-------|
| `cs.started_at::DATE` | `to_business_date(cs.started_at)` | 474, 483, 511, 547, 579, 589 |

Note: line 579 uses `cs2.started_at::DATE` — replace with `to_business_date(cs2.started_at)`.

**Step 2: Apply migration to Supabase**

Use MCP tool:
```
mcp__supabase__execute_sql with the full migration SQL
```

**Step 3: Verify with diagnostic queries**

```sql
-- Test to_business_date: 2026-03-07 01:00 UTC = 2026-03-06 20:00 EST
SELECT to_business_date('2026-03-07 01:00:00+00'::TIMESTAMPTZ);
-- Expected: 2026-03-06

-- Test business_day_start: March 7 Eastern = 05:00 UTC
SELECT business_day_start('2026-03-07'::DATE);
-- Expected: 2026-03-07 05:00:00+00

-- Test business_day_end: March 8 Eastern = 05:00 UTC
SELECT business_day_end('2026-03-07'::DATE);
-- Expected: 2026-03-08 05:00:00+00

-- Verify Moussalifou's fix: activities from yesterday's shift should NOT appear on March 7
SELECT to_business_date(sc.started_at) AS business_date, sc.duration_seconds / 60 AS minutes
FROM stationary_clusters sc
WHERE sc.employee_id = 'd1ed1c21-3406-4511-855b-2f127f66139e'
  AND sc.started_at >= business_day_start('2026-03-07')
  AND sc.started_at < business_day_end('2026-03-07')
  AND sc.duration_seconds >= 180;
-- Expected: only clusters from March 7 Eastern (not the 62-min building from March 6 evening)
```

**Step 4: Commit**

```bash
git add supabase/migrations/139_timezone_standardization.sql
git commit -m "feat: timezone standardization with app_settings + helper functions

Fixes evening activities appearing on wrong day in approval grid.
Creates to_business_date(), business_day_start(), business_day_end()
helpers backed by configurable app_settings.timezone.

Rewrites: get_weekly_approval_summary, get_day_approval_detail,
detect_carpools, get_mileage_summary, get_cleaning_dashboard."
```

---

### Task 2: Dashboard — Create date-utils helper

**Files:**
- Create: `dashboard/src/lib/utils/date-utils.ts`

**Step 1: Create the file**

```typescript
/**
 * Timezone-safe date utilities for RPC parameters.
 *
 * Uses local Date getters (getFullYear, getMonth, getDate) to produce
 * YYYY-MM-DD strings. This avoids the off-by-one bug caused by
 * .toISOString().split('T')[0] which uses UTC date.
 */

/** Format a Date as YYYY-MM-DD using local timezone */
export function toLocalDateString(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** Parse a YYYY-MM-DD string into a Date at noon local (safe for date math) */
export function parseLocalDate(dateStr: string): Date {
  return new Date(dateStr + 'T12:00:00');
}

/** Add days to a YYYY-MM-DD string, returns YYYY-MM-DD */
export function addDays(dateStr: string, days: number): string {
  const d = parseLocalDate(dateStr);
  d.setDate(d.getDate() + days);
  return toLocalDateString(d);
}

/** Get the Monday (ISO week start) of the week containing the given date */
export function getMonday(dateStr?: string): string {
  const d = dateStr ? parseLocalDate(dateStr) : new Date();
  const day = d.getDay();
  d.setDate(d.getDate() - day + (day === 0 ? -6 : 1));
  return toLocalDateString(d);
}
```

**Step 2: Commit**

```bash
git add dashboard/src/lib/utils/date-utils.ts
git commit -m "feat(dashboard): add timezone-safe date-utils helpers"
```

---

### Task 3: Dashboard — Fix approval-grid.tsx

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx`

**Step 1: Replace local helpers with imports**

Remove lines 14-25 (local `getMonday` and `formatDateISO` functions).

Add import at top:
```typescript
import { getMonday, toLocalDateString, parseLocalDate, addDays } from '@/lib/utils/date-utils';
```

**Step 2: Fix `formatShortDate`** (line 27-30)

Already uses `'T12:00:00'` trick — safe. Keep as-is.

**Step 3: Fix `weekStart` state initialization** (line 50)

```typescript
// Before:
const [weekStart, setWeekStart] = useState(() => formatDateISO(getMonday(new Date())));
// After:
const [weekStart, setWeekStart] = useState(() => getMonday());
```

**Step 4: Fix week navigation** (lines 87-89)

```typescript
// Before:
const d = new Date(weekStart + 'T12:00:00');
d.setDate(d.getDate() + direction * 7);
setWeekStart(formatDateISO(d));
// After:
setWeekStart(addDays(weekStart, direction * 7));
```

**Step 5: Fix week label** (lines 121-125)

```typescript
// Before:
const start = new Date(weekStart + 'T12:00:00');
const end = new Date(start);
end.setDate(end.getDate() + 6);
// After:
const start = parseLocalDate(weekStart);
const end = parseLocalDate(addDays(weekStart, 6));
```

**Step 6: Fix weekDates generation** (lines 128-137)

```typescript
const weekDates = useMemo(() => {
  const dates: string[] = [];
  for (let i = 0; i < 7; i++) {
    dates.push(addDays(weekStart, i));
  }
  return dates;
}, [weekStart]);
```

**Step 7: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx
git commit -m "fix(dashboard): approval-grid uses timezone-safe date-utils"
```

---

### Task 4: Dashboard — Fix remaining files

**Files:**
- Modify: `dashboard/src/types/dashboard.ts`
- Modify: `dashboard/src/lib/validations/reports.ts`
- Modify: `dashboard/src/lib/hooks/use-cleaning-sessions.ts`
- Modify: `dashboard/src/components/cleaning/cleaning-filters.tsx`
- Modify: `dashboard/src/components/mileage/stationary-clusters-tab.tsx`
- Modify: `dashboard/src/components/mileage/carpooling-tab.tsx`
- Modify: `dashboard/src/components/mileage/activity-tab.tsx`
- Modify: `dashboard/src/components/mileage/vehicle-periods-tab.tsx`

**Step 1: Fix `dashboard/src/types/dashboard.ts`**

Replace `getDateRangeDates()` (lines 82-110) to return `{ start: string; end: string }`:

```typescript
import { toLocalDateString, addDays, getMonday } from '@/lib/utils/date-utils';

export function getDateRangeDates(range: DateRange): { start: string; end: string } {
  const today = toLocalDateString(new Date());

  switch (range.preset) {
    case 'today':
      return { start: today, end: today };
    case 'this_week':
      return { start: getMonday(today), end: addDays(getMonday(today), 6) };
    case 'this_month': {
      const now = new Date();
      const firstOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);
      const lastOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0);
      return { start: toLocalDateString(firstOfMonth), end: toLocalDateString(lastOfMonth) };
    }
    case 'custom':
      return {
        start: range.start_date ?? toLocalDateString(new Date(new Date().getFullYear(), new Date().getMonth(), 1)),
        end: range.end_date ?? today,
      };
    default: {
      const now = new Date();
      return { start: toLocalDateString(new Date(now.getFullYear(), now.getMonth(), 1)), end: today };
    }
  }
}
```

Update all callers of `getDateRangeDates()` that use `.toISOString()` — they now get strings directly.

**Step 2: Fix `use-cleaning-sessions.ts`**

Replace all `.toISOString().split('T')[0]` with `toLocalDateString()`:
```typescript
import { toLocalDateString } from '@/lib/utils/date-utils';
// ...
p_date_from: toLocalDateString(dateFrom),
p_date_to: toLocalDateString(dateTo),
```

**Step 3: Fix `cleaning-filters.tsx`**

Replace `formatDateInput()`:
```typescript
import { toLocalDateString } from '@/lib/utils/date-utils';
const formatDateInput = (date: Date) => toLocalDateString(date);
```

**Step 4: Fix mileage tabs**

In `stationary-clusters-tab.tsx`, `carpooling-tab.tsx`, `activity-tab.tsx`:
- Replace local `getDefaultDateFrom()` / `formatDateISO()` with imports from `date-utils`
- Replace `d.toISOString().split('T')[0]` with `toLocalDateString(d)`
- Replace `d.setDate(d.getDate() - 30); return d.toISOString().split('T')[0]` with `addDays(toLocalDateString(new Date()), -30)`

In `vehicle-periods-tab.tsx`:
- Replace `new Date().toISOString().split('T')[0]` with `toLocalDateString(new Date())`

In `carpooling-tab.tsx` `handleRedetect` date loop:
```typescript
import { addDays, toLocalDateString } from '@/lib/utils/date-utils';
// Replace the while loop:
let current = detectDateFrom;
const dates: string[] = [];
while (current <= detectDateTo) {
  dates.push(current);
  current = addDays(current, 1);
}
```

**Step 5: Fix `reports.ts`**

Replace `resolveDateRange()` to use `toLocalDateString` and `addDays` from date-utils instead of `new Date(y,m,d)` + `.toISOString().split('T')[0]`.

**Step 6: Commit**

```bash
git add dashboard/src/types/dashboard.ts \
  dashboard/src/lib/validations/reports.ts \
  dashboard/src/lib/hooks/use-cleaning-sessions.ts \
  dashboard/src/components/cleaning/cleaning-filters.tsx \
  dashboard/src/components/mileage/stationary-clusters-tab.tsx \
  dashboard/src/components/mileage/carpooling-tab.tsx \
  dashboard/src/components/mileage/activity-tab.tsx \
  dashboard/src/components/mileage/vehicle-periods-tab.tsx
git commit -m "fix(dashboard): all date helpers use timezone-safe date-utils"
```

---

### Task 5: Flutter — Fix date filter files

**Files:**
- Modify: `gps_tracker/lib/features/history/models/shift_history_filter.dart`
- Modify: `gps_tracker/lib/features/history/services/history_service.dart`
- Modify: `gps_tracker/lib/features/dashboard/services/dashboard_service.dart`

**Step 1: Add a date formatting helper**

In `shift_history_filter.dart`, the `toQueryParams()` method sends full UTC timestamps for DATE parameters. Change to send date-only strings:

```dart
// Before (lines 116-121):
if (startDate != null) {
  params['p_start_date'] = startDate!.toUtc().toIso8601String();
}
if (endDate != null) {
  params['p_end_date'] = endDate!.toUtc().toIso8601String();
}

// After:
if (startDate != null) {
  params['p_start_date'] = '${startDate!.year}-${startDate!.month.toString().padLeft(2, '0')}-${startDate!.day.toString().padLeft(2, '0')}';
}
if (endDate != null) {
  params['p_end_date'] = '${endDate!.year}-${endDate!.month.toString().padLeft(2, '0')}-${endDate!.day.toString().padLeft(2, '0')}';
}
```

Note: `startDate` and `endDate` are created via `DateTime(now.year, now.month, now.day)` which is local time. The `.year`, `.month`, `.day` getters return local components, so this produces the correct local date string.

**Step 2: Fix `history_service.dart`**

Same pattern for `getEmployeeStatistics` (lines 131-136) and `getTeamStatistics` (lines 174-179):

```dart
// Before:
params['p_start_date'] = startDate.toUtc().toIso8601String();
// After:
params['p_start_date'] = '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}';
```

Same for `p_end_date`.

**Step 3: Fix `dashboard_service.dart`**

For `loadTeamStatistics` (line 157-158) and `loadTeamEmployeeHours` (line 176-177):

```dart
// Before:
'p_start_date': startDate?.toUtc().toIso8601String(),
// After:
'p_start_date': startDate != null
    ? '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}'
    : null,
```

Same for `p_end_date` / `endDate`.

**Step 4: Commit**

```bash
cd gps_tracker
git add lib/features/history/models/shift_history_filter.dart \
  lib/features/history/services/history_service.dart \
  lib/features/dashboard/services/dashboard_service.dart
git commit -m "fix(flutter): send date-only strings for RPC date parameters"
```

---

### Task 6: Verification

**Step 1: Verify SQL helpers work**

Run the diagnostic queries from Task 1, Step 3.

**Step 2: Verify Moussalifou's fix**

```sql
-- Call the fixed weekly summary for this week
SELECT jsonb_pretty(get_weekly_approval_summary('2026-03-02'::DATE));
-- Check Moussalifou's March 7 entry: should NOT show 1h02 from yesterday's activities
```

**Step 3: Verify detail view matches grid**

```sql
-- Call the fixed day detail
SELECT jsonb_pretty(get_day_approval_detail(
    'd1ed1c21-3406-4511-855b-2f127f66139e'::UUID,
    '2026-03-07'::DATE
));
-- approved_minutes and total_shift_minutes should match what the grid shows
```

**Step 4: Build dashboard**

```bash
cd dashboard && npm run build
```

**Step 5: Analyze Flutter**

```bash
cd gps_tracker && flutter analyze
```

**Step 6: Final commit (if any fixes needed)**

---

### Task 7: Deploy

Use the `deploy` skill or manual process to push the migration and app updates.
