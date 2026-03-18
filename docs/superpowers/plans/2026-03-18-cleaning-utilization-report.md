# Cleaning Utilization Report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dashboard page showing per-employee work session utilization %, GPS accuracy %, and time breakdown (short-term units, common areas, long-term cleaning, long-term maintenance, office) for cleaning/maintenance employees.

**Architecture:** Single Supabase RPC computes all metrics server-side using CTEs (shifts → trips → work_sessions → gps_points → locations). Next.js page calls the RPC via Refine's `useCustom` hook and renders a table with colored progress bars.

**Tech Stack:** PostgreSQL/PostGIS (RPC), Next.js 14+ (App Router), shadcn/ui, Refine `useCustom`, lucide-react icons.

**Spec:** `docs/superpowers/specs/2026-03-18-cleaning-utilization-report-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20260318100000_cleaning_utilization_report.sql` | RPC `get_cleaning_utilization_report` |
| `dashboard/src/lib/hooks/use-cleaning-utilization.ts` | Data-fetching hook (Refine `useCustom` → RPC) |
| `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx` | Page with filters + table |
| `dashboard/src/app/dashboard/reports/page.tsx` | Add report card (modify) |
| `dashboard/src/types/reports.ts` | Add `cleaning_utilization` to ReportType (modify) |

---

## Task 1: Create Supabase RPC migration

**Files:**
- Create: `supabase/migrations/20260318100000_cleaning_utilization_report.sql`

- [ ] **Step 1: Write the RPC**

```sql
-- =============================================================================
-- Migration: 20260318100000_cleaning_utilization_report
-- Description: RPC for cleaning/work session utilization report per employee
-- Returns: utilization %, GPS accuracy %, time breakdown by location category
-- =============================================================================

CREATE OR REPLACE FUNCTION get_cleaning_utilization_report(
  p_date_from DATE,
  p_date_to DATE,
  p_employee_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path TO public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_office_location_id UUID;
  v_office_geo geography;
  v_office_radius NUMERIC;
BEGIN
  -- Resolve office location (151-159_Principale, is_also_office = true)
  SELECT id, location, radius_meters
  INTO v_office_location_id, v_office_geo, v_office_radius
  FROM locations
  WHERE is_also_office = true AND is_active = true
  LIMIT 1;

  WITH employee_shifts AS (
    -- Completed non-lunch shifts in date range
    SELECT
      s.employee_id,
      s.id AS shift_id,
      s.clocked_in_at,
      s.clocked_out_at,
      EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60.0 AS shift_minutes
    FROM shifts s
    WHERE s.status = 'completed'
      AND s.is_lunch IS NOT TRUE
      AND s.clocked_in_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  shift_agg AS (
    SELECT
      employee_id,
      SUM(shift_minutes) AS total_shift_minutes,
      COUNT(*) AS total_shifts
    FROM employee_shifts
    GROUP BY employee_id
  ),
  employee_trips AS (
    -- Sum trip durations for those shifts
    SELECT
      es.employee_id,
      COALESCE(SUM(t.duration_minutes), 0) AS trip_minutes
    FROM employee_shifts es
    LEFT JOIN trips t ON t.shift_id = es.shift_id
    GROUP BY es.employee_id
  ),
  employee_sessions AS (
    -- Session durations with category breakdown
    SELECT
      ws.employee_id,
      SUM(ws.duration_minutes) AS total_session_minutes,
      COUNT(*) AS total_sessions,
      -- Short-term: studio-based
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.studio_id IS NOT NULL AND st.studio_type = 'unit'), 0)
        AS short_term_unit_minutes,
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.studio_id IS NOT NULL AND st.studio_type IN ('common_area', 'conciergerie')), 0)
        AS short_term_common_minutes,
      -- Long-term: property_building-based
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.building_id IS NOT NULL AND ws.activity_type = 'cleaning'), 0)
        AS cleaning_long_term_minutes,
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.building_id IS NOT NULL AND ws.activity_type = 'maintenance'), 0)
        AS maintenance_long_term_minutes
    FROM work_sessions ws
    LEFT JOIN studios st ON st.id = ws.studio_id
    WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    GROUP BY ws.employee_id
  ),
  employee_accuracy AS (
    -- GPS accuracy: % of points within session building's geofence
    SELECT
      ws.employee_id,
      COUNT(gp.id) AS total_gps_points,
      COUNT(gp.id) FILTER (WHERE
        loc.id IS NOT NULL AND
        ST_DWithin(
          loc.location,
          ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
          loc.radius_meters
        )
      ) AS points_in_geofence
    FROM work_sessions ws
    JOIN employee_shifts es ON es.shift_id = ws.shift_id
    JOIN gps_points gp ON gp.shift_id = ws.shift_id
      AND gp.captured_at BETWEEN ws.started_at AND ws.completed_at
      AND gp.accuracy <= 50
    LEFT JOIN studios st ON st.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = st.building_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN locations loc ON loc.id = COALESCE(b.location_id, pb.location_id)
    WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    GROUP BY ws.employee_id
  ),
  office_gps AS (
    -- GPS points at office NOT during any work session
    SELECT
      es.employee_id,
      gp.captured_at,
      LAG(gp.captured_at) OVER (
        PARTITION BY es.employee_id, es.shift_id
        ORDER BY gp.captured_at
      ) AS prev_captured_at
    FROM employee_shifts es
    JOIN gps_points gp ON gp.shift_id = es.shift_id
      AND gp.accuracy <= 50
    WHERE v_office_geo IS NOT NULL
      AND ST_DWithin(
        v_office_geo,
        ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
        v_office_radius
      )
      -- Exclude GPS during work sessions
      AND NOT EXISTS (
        SELECT 1 FROM work_sessions ws2
        WHERE ws2.shift_id = es.shift_id
          AND ws2.employee_id = es.employee_id
          AND ws2.status IN ('completed', 'auto_closed', 'manually_closed', 'in_progress')
          AND gp.captured_at BETWEEN ws2.started_at AND COALESCE(ws2.completed_at, now())
      )
  ),
  employee_office AS (
    SELECT
      employee_id,
      -- Sum intervals between consecutive GPS points, capped at 5 min each
      COALESCE(SUM(
        LEAST(
          EXTRACT(EPOCH FROM (captured_at - prev_captured_at)) / 60.0,
          5.0
        )
      ), 0) AS office_minutes
    FROM office_gps
    WHERE prev_captured_at IS NOT NULL
    GROUP BY employee_id
  )
  SELECT jsonb_build_object(
    'employees', COALESCE(jsonb_agg(
      jsonb_build_object(
        'employee_id', ep.id,
        'employee_name', ep.full_name,
        'total_shift_minutes', round(COALESCE(sa.total_shift_minutes, 0), 1),
        'total_trip_minutes', round(COALESCE(et.trip_minutes, 0), 1),
        'total_session_minutes', round(COALESCE(esn.total_session_minutes, 0), 1),
        'available_minutes', round(
          GREATEST(COALESCE(sa.total_shift_minutes, 0) - COALESCE(et.trip_minutes, 0), 0), 1),
        'utilization_pct', CASE
          WHEN COALESCE(sa.total_shift_minutes, 0) - COALESCE(et.trip_minutes, 0) > 0
          THEN round(
            COALESCE(esn.total_session_minutes, 0)
            / (sa.total_shift_minutes - COALESCE(et.trip_minutes, 0))
            * 100, 1)
          ELSE 0
        END,
        'accuracy_pct', CASE
          WHEN COALESCE(ea.total_gps_points, 0) > 0
          THEN round(ea.points_in_geofence::numeric / ea.total_gps_points * 100, 1)
          ELSE NULL
        END,
        'short_term_unit_minutes', round(COALESCE(esn.short_term_unit_minutes, 0), 1),
        'short_term_common_minutes', round(COALESCE(esn.short_term_common_minutes, 0), 1),
        'cleaning_long_term_minutes', round(COALESCE(esn.cleaning_long_term_minutes, 0), 1),
        'maintenance_long_term_minutes', round(COALESCE(esn.maintenance_long_term_minutes, 0), 1),
        'office_minutes', round(COALESCE(eo.office_minutes, 0), 1),
        'total_sessions', COALESCE(esn.total_sessions, 0),
        'total_shifts', COALESCE(sa.total_shifts, 0)
      )
    ORDER BY ep.full_name), '[]'::jsonb)
  ) INTO v_result
  FROM shift_agg sa
  JOIN employee_profiles ep ON ep.id = sa.employee_id
  LEFT JOIN employee_trips et ON et.employee_id = sa.employee_id
  LEFT JOIN employee_sessions esn ON esn.employee_id = sa.employee_id
  LEFT JOIN employee_accuracy ea ON ea.employee_id = sa.employee_id
  LEFT JOIN employee_office eo ON eo.employee_id = sa.employee_id;

  RETURN COALESCE(v_result, jsonb_build_object('employees', '[]'::jsonb));
END;
$$;

-- Comments
COMMENT ON FUNCTION get_cleaning_utilization_report IS 'ROLE: Dashboard report — per-employee work session utilization %, GPS accuracy %, and time breakdown by location type.
PARAMS: p_date_from/p_date_to filter shifts by clocked_in_at date; p_employee_id optional single-employee filter.
REGLES: Excludes lunch shifts (is_lunch=true), in-progress shifts/sessions. GPS accuracy filters points <=50m. Office time = GPS at is_also_office location minus work session overlaps.
RELATIONS: shifts, work_sessions, trips, gps_points, studios→buildings→locations, property_buildings→locations';
```

- [ ] **Step 2: Apply the migration**

Run via Supabase MCP `apply_migration` tool.

- [ ] **Step 3: Test RPC with real data**

```sql
-- Test with last 7 days
SELECT * FROM get_cleaning_utilization_report(
  (CURRENT_DATE - INTERVAL '7 days')::date,
  CURRENT_DATE
);
```

Verify:
- Returns JSON with `employees` array
- Each employee has all expected fields
- `utilization_pct` is between 0-100 (or >100 if session time exceeds available)
- `accuracy_pct` is NULL or between 0-100
- Time breakdown minutes sum roughly to `total_session_minutes` (excluding office)

- [ ] **Step 4: Test single-employee filter**

```sql
-- Test with a known employee (Cedric Lajoie)
SELECT * FROM get_cleaning_utilization_report(
  (CURRENT_DATE - INTERVAL '30 days')::date,
  CURRENT_DATE,
  (SELECT id FROM employee_profiles WHERE full_name ILIKE '%cedric%lajoie%')
);
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260318100000_cleaning_utilization_report.sql
git commit -m "feat(db): add get_cleaning_utilization_report RPC

Computes per-employee: utilization %, GPS accuracy %, time breakdown
by location category (short-term units/common, long-term cleaning/
maintenance, office)."
```

---

## Task 2: Create data-fetching hook

**Files:**
- Create: `dashboard/src/lib/hooks/use-cleaning-utilization.ts`

**Context:**
- Follow pattern from `dashboard/src/lib/hooks/use-work-sessions.ts`
- Use Refine `useCustom` with `meta: { rpc: 'get_cleaning_utilization_report' }`
- Helper: `toLocalDateString` from `@/lib/utils/date-utils`

- [ ] **Step 1: Create the hook**

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import { toLocalDateString } from '@/lib/utils/date-utils';

export interface CleaningUtilizationEmployee {
  employee_id: string;
  employee_name: string;
  total_shift_minutes: number;
  total_trip_minutes: number;
  total_session_minutes: number;
  available_minutes: number;
  utilization_pct: number;
  accuracy_pct: number | null;
  short_term_unit_minutes: number;
  short_term_common_minutes: number;
  cleaning_long_term_minutes: number;
  maintenance_long_term_minutes: number;
  office_minutes: number;
  total_sessions: number;
  total_shifts: number;
}

interface RpcResponse {
  employees: CleaningUtilizationEmployee[];
}

interface UseCleaningUtilizationParams {
  dateFrom: Date;
  dateTo: Date;
  employeeId?: string;
}

export function useCleaningUtilization({
  dateFrom,
  dateTo,
  employeeId,
}: UseCleaningUtilizationParams) {
  const { query, result } = useCustom<RpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_cleaning_utilization_report',
    },
    config: {
      payload: {
        p_date_from: toLocalDateString(dateFrom),
        p_date_to: toLocalDateString(dateTo),
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
    },
  });

  const rawData = result?.data as RpcResponse | undefined;

  const employees = useMemo(() => {
    if (!rawData?.employees) return [];
    return rawData.employees;
  }, [rawData]);

  const totals = useMemo(() => {
    if (employees.length === 0) return null;
    const sum = (key: keyof CleaningUtilizationEmployee) =>
      employees.reduce((acc, e) => acc + ((e[key] as number) ?? 0), 0);

    const totalShift = sum('total_shift_minutes');
    const totalTrip = sum('total_trip_minutes');
    const totalSession = sum('total_session_minutes');
    const available = Math.max(totalShift - totalTrip, 0);

    const totalGpsEmployees = employees.filter((e) => e.accuracy_pct !== null);
    const avgAccuracy =
      totalGpsEmployees.length > 0
        ? totalGpsEmployees.reduce((a, e) => a + (e.accuracy_pct ?? 0), 0) /
          totalGpsEmployees.length
        : null;

    return {
      total_shift_minutes: totalShift,
      total_trip_minutes: totalTrip,
      total_session_minutes: totalSession,
      available_minutes: available,
      utilization_pct: available > 0 ? (totalSession / available) * 100 : 0,
      accuracy_pct: avgAccuracy !== null ? Math.round(avgAccuracy * 10) / 10 : null,
      short_term_unit_minutes: sum('short_term_unit_minutes'),
      short_term_common_minutes: sum('short_term_common_minutes'),
      cleaning_long_term_minutes: sum('cleaning_long_term_minutes'),
      maintenance_long_term_minutes: sum('maintenance_long_term_minutes'),
      office_minutes: sum('office_minutes'),
      employee_count: employees.length,
    };
  }, [employees]);

  return {
    employees,
    totals,
    isLoading: query.isLoading,
    error: query.error,
    refetch: query.refetch,
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/hooks/use-cleaning-utilization.ts
git commit -m "feat(dashboard): add useCleaningUtilization hook"
```

---

## Task 3: Create the report page

**Files:**
- Create: `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx`

**Context:**
- Follow layout pattern from `dashboard/src/app/dashboard/work-sessions/page.tsx` (filters + table)
- Date inputs use `<input type="date">` with `toLocalDateString`
- Employee dropdown: call `get_supervised_employees_list` RPC (existing pattern from timesheet page)
- Progress bars: inline div with width % and background color based on thresholds
- Format minutes → hours: `(minutes / 60).toFixed(1) + 'h'`

- [ ] **Step 1: Create the page component**

```tsx
'use client';

import { useState, useMemo } from 'react';
import { useCustom } from '@refinedev/core';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { toLocalDateString } from '@/lib/utils/date-utils';
import {
  useCleaningUtilization,
  type CleaningUtilizationEmployee,
} from '@/lib/hooks/use-cleaning-utilization';
import { subDays } from 'date-fns';

function formatHours(minutes: number): string {
  return (minutes / 60).toFixed(1) + 'h';
}

function PercentBar({ value, thresholds }: {
  value: number | null;
  thresholds: { green: number; yellow: number };
}) {
  if (value === null) return <span className="text-sm text-slate-400">N/A</span>;
  const color =
    value >= thresholds.green
      ? 'bg-emerald-500'
      : value >= thresholds.yellow
        ? 'bg-amber-500'
        : 'bg-red-500';
  return (
    <div className="flex items-center gap-2">
      <div className="h-2 w-20 rounded-full bg-slate-100">
        <div
          className={`h-2 rounded-full ${color}`}
          style={{ width: `${Math.min(value, 100)}%` }}
        />
      </div>
      <span className="text-sm font-medium">{value.toFixed(1)}%</span>
    </div>
  );
}

export default function CleaningUtilizationPage() {
  const [dateFrom, setDateFrom] = useState(() => subDays(new Date(), 7));
  const [dateTo, setDateTo] = useState(() => new Date());
  const [employeeId, setEmployeeId] = useState<string>('');

  // Fetch employee list for filter
  const { result: empResult } = useCustom({
    url: '',
    method: 'get',
    meta: { rpc: 'get_supervised_employees_list' },
    config: { payload: {} as Record<string, unknown> },
    queryOptions: { staleTime: 60 * 1000 },
  });

  const employeeOptions = useMemo(() => {
    const raw = empResult?.data as unknown as Array<{
      id: string;
      full_name: string;
    }> | undefined;
    if (!raw) return [];
    return [...raw].sort((a, b) => a.full_name.localeCompare(b.full_name));
  }, [empResult]);

  const { employees, totals, isLoading } = useCleaningUtilization({
    dateFrom,
    dateTo,
    employeeId: employeeId || undefined,
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">
          Utilisation ménage
        </h1>
        <p className="mt-1 text-sm text-slate-500">
          Taux d&apos;utilisation et précision GPS par employé
        </p>
      </div>

      {/* Filters */}
      <Card>
        <CardContent className="pt-6">
          <div className="flex flex-wrap items-end gap-4">
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Du
              </label>
              <input
                type="date"
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={toLocalDateString(dateFrom)}
                onChange={(e) =>
                  setDateFrom(new Date(e.target.value + 'T00:00:00'))
                }
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Au
              </label>
              <input
                type="date"
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={toLocalDateString(dateTo)}
                onChange={(e) =>
                  setDateTo(new Date(e.target.value + 'T00:00:00'))
                }
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Employé
              </label>
              <select
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={employeeId}
                onChange={(e) => setEmployeeId(e.target.value)}
              >
                <option value="">Tous les employés</option>
                {employeeOptions.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Table */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Résultats</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="py-12 text-center text-sm text-slate-400">
              Chargement...
            </div>
          ) : employees.length === 0 ? (
            <div className="py-12 text-center text-sm text-slate-400">
              Aucune donnée pour la période sélectionnée
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-xs font-medium uppercase text-slate-500">
                    <th className="pb-3 pr-4">Employé</th>
                    <th className="pb-3 pr-4 text-right">Shifts</th>
                    <th className="pb-3 pr-4 text-right">Déplacements</th>
                    <th className="pb-3 pr-4 text-right">Sessions</th>
                    <th className="pb-3 pr-4">Utilisation</th>
                    <th className="pb-3 pr-4">Accuracy</th>
                    <th className="pb-3 pr-4 text-right">Unités CT</th>
                    <th className="pb-3 pr-4 text-right">Aires comm. CT</th>
                    <th className="pb-3 pr-4 text-right">Ménage LT</th>
                    <th className="pb-3 pr-4 text-right">Entretien LT</th>
                    <th className="pb-3 text-right">Bureau</th>
                  </tr>
                </thead>
                <tbody>
                  {employees.map((emp: CleaningUtilizationEmployee) => (
                    <tr
                      key={emp.employee_id}
                      className="border-b last:border-0"
                    >
                      <td className="py-3 pr-4 font-medium">
                        {emp.employee_name}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_shift_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_trip_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_session_minutes)}
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={emp.utilization_pct}
                          thresholds={{ green: 80, yellow: 60 }}
                        />
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={emp.accuracy_pct}
                          thresholds={{ green: 90, yellow: 70 }}
                        />
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.short_term_unit_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.short_term_common_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.cleaning_long_term_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.maintenance_long_term_minutes)}
                      </td>
                      <td className="py-3 text-right">
                        {formatHours(emp.office_minutes)}
                      </td>
                    </tr>
                  ))}
                </tbody>
                {/* Footer totals */}
                {totals && (
                  <tfoot>
                    <tr className="border-t-2 font-semibold">
                      <td className="py-3 pr-4">
                        Totaux ({totals.employee_count} employés)
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_shift_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_trip_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_session_minutes)}
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={totals.utilization_pct}
                          thresholds={{ green: 80, yellow: 60 }}
                        />
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={totals.accuracy_pct}
                          thresholds={{ green: 90, yellow: 70 }}
                        />
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.short_term_unit_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.short_term_common_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.cleaning_long_term_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.maintenance_long_term_minutes)}
                      </td>
                      <td className="py-3 text-right">
                        {formatHours(totals.office_minutes)}
                      </td>
                    </tr>
                  </tfoot>
                )}
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx
git commit -m "feat(dashboard): add cleaning utilization report page"
```

---

## Task 4: Add report card to reports hub

**Files:**
- Modify: `dashboard/src/types/reports.ts:7` — add `cleaning_utilization` to `ReportType`
- Modify: `dashboard/src/app/dashboard/reports/page.tsx:32-89` — add card to `reportCards` array

- [ ] **Step 1: Add ReportType**

In `dashboard/src/types/reports.ts`, change:
```typescript
export type ReportType = 'timesheet' | 'activity_summary' | 'attendance' | 'shift_history';
```
to:
```typescript
export type ReportType = 'timesheet' | 'activity_summary' | 'attendance' | 'shift_history' | 'cleaning_utilization';
```

- [ ] **Step 2: Update REPORT_TYPE_INFO constant**

In `dashboard/src/types/reports.ts`, add entry to `REPORT_TYPE_INFO` record (after the last entry):
```typescript
  cleaning_utilization: {
    label: 'Utilisation ménage',
    description: 'Taux d\'utilisation et précision GPS des employés de ménage',
  },
```

- [ ] **Step 3: Add report card**

In `dashboard/src/app/dashboard/reports/page.tsx`, add `Sparkles` to the lucide-react import:
```typescript
import {
  Clock,
  Users,
  Calendar,
  FileDown,
  ArrowRight,
  Sparkles,
} from 'lucide-react';
```

Then add this card to the `reportCards` array after the last entry:

```typescript
  {
    type: 'cleaning_utilization',
    title: 'Utilisation ménage',
    description: 'Taux d\'utilisation et précision GPS des employés de ménage',
    icon: Sparkles,
    href: '/dashboard/reports/cleaning-utilization',
    features: [
      'Utilisation % (sessions / temps disponible)',
      'Précision GPS % par session',
      'Ventilation: unités CT, aires communes, LT, bureau',
      'Filtrage par employé et plage de dates',
    ],
    priority: 'P1',
  },
```

- [ ] **Step 4: Verify build**

```bash
cd dashboard && npm run build
```

Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/types/reports.ts dashboard/src/app/dashboard/reports/page.tsx
git commit -m "feat(dashboard): add cleaning utilization card to reports hub"
```

---

## Task 5: Integration test — verify end-to-end

- [ ] **Step 1: Run dev server and verify page loads**

```bash
cd dashboard && npm run dev
```

Navigate to `http://localhost:3000/dashboard/reports/cleaning-utilization`.
Verify:
- Page renders with filters and table
- Date range defaults to last 7 days
- Employee dropdown populates
- Data loads from RPC (or shows "Aucune donnée" if no shifts in range)
- Progress bars render with correct colors
- Footer totals row appears

- [ ] **Step 2: Verify reports hub card**

Navigate to `http://localhost:3000/dashboard/reports`.
Verify: "Utilisation ménage" card appears with link to the new page.

- [ ] **Step 3: Final commit if any fixes needed**

```bash
git add -A && git commit -m "fix: polish cleaning utilization report"
```
