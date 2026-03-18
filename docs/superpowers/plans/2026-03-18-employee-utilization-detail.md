# Employee Utilization Detail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drill-down page per employee showing daily timelines (color-coded clusters/trips) and a cluster detail table to understand utilization and accuracy data.

**Architecture:** New Supabase RPC returns clusters + trips + sessions grouped by day/shift. Next.js page renders interactive timeline bars and a filterable table. Linked from main report via employee name click.

**Tech Stack:** PostgreSQL/PostGIS (RPC), Next.js 14+ (App Router), shadcn/ui, Refine `useCustom`, date-fns, lucide-react.

**Spec:** `docs/superpowers/specs/2026-03-18-employee-utilization-detail-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20260318300000_employee_utilization_detail.sql` | RPC `get_employee_utilization_detail` |
| `dashboard/src/lib/hooks/use-employee-utilization-detail.ts` | Data-fetching hook |
| `dashboard/src/app/dashboard/reports/cleaning-utilization/[employeeId]/page.tsx` | Detail page with timeline + table |
| `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx` | Modify: employee name as Link |

---

## Task 1: Create Supabase RPC

**Files:**
- Create: `supabase/migrations/20260318300000_employee_utilization_detail.sql`

- [ ] **Step 1: Write the RPC**

```sql
-- =============================================================================
-- Migration: 20260318300000_employee_utilization_detail
-- Description: Drill-down RPC for a single employee's utilization detail
-- Returns: clusters, trips, sessions grouped by day/shift with location match info
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_utilization_detail(
  p_employee_id UUID,
  p_date_from DATE,
  p_date_to DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path TO public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_employee_name TEXT;
  v_summary JSONB;
  v_days JSONB;
BEGIN
  -- Get employee name
  SELECT full_name INTO v_employee_name
  FROM employee_profiles WHERE id = p_employee_id;

  IF v_employee_name IS NULL THEN
    RETURN jsonb_build_object('error', 'EMPLOYEE_NOT_FOUND');
  END IF;

  -- Summary (reuse main report logic for single employee)
  SELECT r->'employees'->0 INTO v_summary
  FROM get_cleaning_utilization_report(p_date_from, p_date_to, p_employee_id) r;

  -- Days: one entry per shift with clusters and trips
  WITH employee_shifts AS (
    SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at,
      s.clocked_in_at::date AS shift_date,
      EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60.0 AS shift_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.status = 'completed' AND s.is_lunch IS NOT TRUE
      AND s.clocked_in_at::date BETWEEN p_date_from AND p_date_to
  ),
  shift_clusters AS (
    SELECT
      sc.shift_id,
      jsonb_agg(jsonb_build_object(
        'started_at', sc.started_at,
        'ended_at', sc.ended_at,
        'duration_minutes', round(sc.duration_seconds / 60.0, 1),
        'physical_location', COALESCE(loc.name, 'Non identifie'),
        'physical_location_id', sc.matched_location_id,
        'session_building', CASE
          WHEN ws.id IS NULL THEN NULL
          WHEN ws.activity_type = 'admin' THEN 'Admin'
          ELSE ws.activity_type || ' @ ' || COALESCE(b.name, pb.name, 'Inconnu')
        END,
        'session_location_id', COALESCE(b_loc.id, pb_loc.id),
        'session_activity_type', ws.activity_type,
        'match', CASE
          WHEN ws.id IS NULL THEN NULL
          WHEN ws.activity_type = 'admin' THEN NULL
          WHEN COALESCE(b_loc.id, pb_loc.id) IS NULL THEN NULL
          ELSE sc.matched_location_id = COALESCE(b_loc.id, pb_loc.id)
        END,
        'location_category', CASE
          WHEN ws.id IS NULL THEN NULL
          WHEN ws.activity_type = 'admin' AND loc.is_also_office = true THEN 'office'
          WHEN ws.activity_type = 'admin' AND loc.is_employee_home = true THEN 'home'
          WHEN ws.activity_type = 'admin' THEN NULL
          WHEN COALESCE(b_loc.id, pb_loc.id) IS NOT NULL
            AND sc.matched_location_id = COALESCE(b_loc.id, pb_loc.id) THEN 'match'
          ELSE 'mismatch'
        END
      ) ORDER BY sc.started_at) AS clusters
    FROM stationary_clusters sc
    JOIN employee_shifts es ON es.shift_id = sc.shift_id
    LEFT JOIN locations loc ON loc.id = sc.matched_location_id
    -- Find overlapping work session
    LEFT JOIN LATERAL (
      SELECT ws2.id, ws2.activity_type, ws2.studio_id, ws2.building_id
      FROM work_sessions ws2
      WHERE ws2.shift_id = sc.shift_id
        AND ws2.employee_id = p_employee_id
        AND ws2.status IN ('completed', 'auto_closed', 'manually_closed')
        AND sc.started_at < ws2.completed_at AND sc.ended_at > ws2.started_at
      ORDER BY ws2.started_at
      LIMIT 1
    ) ws ON true
    -- Resolve session building location
    LEFT JOIN studios st ON st.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = st.building_id
    LEFT JOIN locations b_loc ON b_loc.id = b.location_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN locations pb_loc ON pb_loc.id = pb.location_id
    GROUP BY sc.shift_id
  ),
  shift_trips AS (
    SELECT t.shift_id,
      jsonb_agg(jsonb_build_object(
        'started_at', t.started_at,
        'ended_at', t.ended_at,
        'duration_minutes', t.duration_minutes
      ) ORDER BY t.started_at) AS trips
    FROM trips t
    JOIN employee_shifts es ON es.shift_id = t.shift_id
    GROUP BY t.shift_id
  ),
  shift_session_minutes AS (
    SELECT ws.shift_id,
      SUM(GREATEST(EXTRACT(EPOCH FROM (
        LEAST(ws.completed_at, es.clocked_out_at) - GREATEST(ws.started_at, es.clocked_in_at)
      )) / 60.0, 0)) AS session_minutes
    FROM work_sessions ws
    JOIN employee_shifts es ON es.shift_id = ws.shift_id
    WHERE ws.employee_id = p_employee_id
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
    GROUP BY ws.shift_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date', es.shift_date,
    'shift_id', es.shift_id,
    'clocked_in_at', es.clocked_in_at,
    'clocked_out_at', es.clocked_out_at,
    'shift_minutes', round(es.shift_minutes, 1),
    'session_minutes', round(COALESCE(ssm.session_minutes, 0), 1),
    'trip_minutes', COALESCE((
      SELECT SUM((t->>'duration_minutes')::numeric) FROM jsonb_array_elements(st2.trips) t
    ), 0),
    'clusters', COALESCE(sc2.clusters, '[]'::jsonb),
    'trips', COALESCE(st2.trips, '[]'::jsonb)
  ) ORDER BY es.shift_date, es.clocked_in_at), '[]'::jsonb)
  INTO v_days
  FROM employee_shifts es
  LEFT JOIN shift_clusters sc2 ON sc2.shift_id = es.shift_id
  LEFT JOIN shift_trips st2 ON st2.shift_id = es.shift_id
  LEFT JOIN shift_session_minutes ssm ON ssm.shift_id = es.shift_id;

  RETURN jsonb_build_object(
    'employee_name', v_employee_name,
    'employee_id', p_employee_id,
    'summary', v_summary,
    'days', v_days
  );
END;
$$;

COMMENT ON FUNCTION get_employee_utilization_detail IS 'ROLE: Drill-down for single employee utilization.
PARAMS: p_employee_id, p_date_from, p_date_to.
REGLES: Returns clusters with location_category (match/mismatch/office/home/null), trips, and session overlap per shift/day.
RELATIONS: shifts, stationary_clusters, work_sessions, trips, locations, studios→buildings, property_buildings';
```

- [ ] **Step 2: Apply the migration**

Apply via Supabase MCP `apply_migration` tool.

- [ ] **Step 3: Test with real data**

```sql
-- Test with Rostang Noumi (low accuracy)
SELECT jsonb_pretty(get_employee_utilization_detail(
  (SELECT id FROM employee_profiles WHERE full_name = 'Rostang Noumi'),
  '2026-03-11'::date, '2026-03-13'::date
));
```

Verify:
- Returns JSON with `employee_name`, `summary`, `days` array
- Each day has `clusters` with `location_category` (match/mismatch)
- Trips array populated
- Summary matches main report for same employee

```sql
-- Test with Fatima (admin only)
SELECT jsonb_pretty(get_employee_utilization_detail(
  (SELECT id FROM employee_profiles WHERE full_name ILIKE '%fatima%rechka%'),
  '2026-03-11'::date, '2026-03-18'::date
));
```

Verify: clusters have `location_category` = "office" or "home", `match` = null.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260318300000_employee_utilization_detail.sql
git commit -m "feat(db): add get_employee_utilization_detail RPC

Returns clusters, trips, sessions grouped by day/shift for a single
employee. Includes location_category (match/mismatch/office/home)."
```

---

## Task 2: Create data-fetching hook

**Files:**
- Create: `dashboard/src/lib/hooks/use-employee-utilization-detail.ts`

**Context:**
- Follow pattern from `dashboard/src/lib/hooks/use-cleaning-utilization.ts`
- Use `const { query, result } = useCustom<T>(...)` then `result?.data as T`

- [ ] **Step 1: Create the hook**

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import { toLocalDateString } from '@/lib/utils/date-utils';

export interface ClusterDetail {
  started_at: string;
  ended_at: string;
  duration_minutes: number;
  physical_location: string;
  physical_location_id: string | null;
  session_building: string | null;
  session_location_id: string | null;
  session_activity_type: string | null;
  match: boolean | null;
  location_category: 'match' | 'mismatch' | 'office' | 'home' | null;
}

export interface TripDetail {
  started_at: string;
  ended_at: string;
  duration_minutes: number;
}

export interface DayDetail {
  date: string;
  shift_id: string;
  clocked_in_at: string;
  clocked_out_at: string;
  shift_minutes: number;
  session_minutes: number;
  trip_minutes: number;
  clusters: ClusterDetail[];
  trips: TripDetail[];
}

export interface EmployeeSummary {
  total_shift_minutes: number;
  total_trip_minutes: number;
  total_session_minutes: number;
  utilization_pct: number;
  accuracy_pct: number | null;
  total_shifts: number;
  total_sessions: number;
}

interface RpcResponse {
  employee_name: string;
  employee_id: string;
  summary: EmployeeSummary | null;
  days: DayDetail[];
}

interface UseEmployeeUtilizationDetailParams {
  employeeId: string;
  dateFrom: Date;
  dateTo: Date;
}

export function useEmployeeUtilizationDetail({
  employeeId,
  dateFrom,
  dateTo,
}: UseEmployeeUtilizationDetailParams) {
  const { query, result } = useCustom<RpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_employee_utilization_detail',
    },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_date_from: toLocalDateString(dateFrom),
        p_date_to: toLocalDateString(dateTo),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
      enabled: !!employeeId,
    },
  });

  const rawData = result?.data as RpcResponse | undefined;

  const data = useMemo(() => {
    if (!rawData) return null;
    return {
      employeeName: rawData.employee_name,
      employeeId: rawData.employee_id,
      summary: rawData.summary,
      days: rawData.days ?? [],
    };
  }, [rawData]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.error,
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/hooks/use-employee-utilization-detail.ts
git commit -m "feat(dashboard): add useEmployeeUtilizationDetail hook"
```

---

## Task 3: Create the detail page

**Files:**
- Create: `dashboard/src/app/dashboard/reports/cleaning-utilization/[employeeId]/page.tsx`

**Context:**
- Route receives `employeeId` as path param, `from`/`to` as query params
- Use `useSearchParams()` for query params, `useParams()` for path param
- Timeline: horizontal div bars with absolute-positioned colored segments
- Table: HTML table with conditional red background for mismatches
- Click on a day timeline → `setSelectedDate(date)` → filters table

- [ ] **Step 1: Create the page**

```tsx
'use client';

import { useState, useMemo } from 'react';
import { useParams, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { toLocalDateString } from '@/lib/utils/date-utils';
import {
  useEmployeeUtilizationDetail,
  type DayDetail,
  type ClusterDetail,
} from '@/lib/hooks/use-employee-utilization-detail';
import { format, parseISO, subDays } from 'date-fns';
import { fr } from 'date-fns/locale';

function formatHours(minutes: number): string {
  return (minutes / 60).toFixed(1) + 'h';
}

function PercentBar({ value, thresholds }: {
  value: number | null;
  thresholds: { green: number; yellow: number };
}) {
  if (value === null) return <span className="text-sm text-slate-400">N/A</span>;
  const color = value >= thresholds.green ? 'text-emerald-600'
    : value >= thresholds.yellow ? 'text-amber-600' : 'text-red-600';
  return <span className={`font-semibold ${color}`}>{value.toFixed(1)}%</span>;
}

const CATEGORY_COLORS: Record<string, string> = {
  match: '#10b981',
  mismatch: '#ef4444',
  office: '#3b82f6',
  home: '#8b5cf6',
};
const TRIP_COLOR = '#f59e0b';
const EMPTY_COLOR = '#e2e8f0';

function DayTimeline({
  day,
  isSelected,
  onClick,
}: {
  day: DayDetail;
  isSelected: boolean;
  onClick: () => void;
}) {
  const shiftStart = new Date(day.clocked_in_at).getTime();
  const shiftEnd = new Date(day.clocked_out_at).getTime();
  const shiftDuration = shiftEnd - shiftStart;
  if (shiftDuration <= 0) return null;

  const toPercent = (time: string) => {
    const t = new Date(time).getTime();
    return Math.max(0, Math.min(100, ((t - shiftStart) / shiftDuration) * 100));
  };

  const segments: Array<{ left: number; width: number; color: string }> = [];

  // Clusters
  for (const c of day.clusters) {
    const left = toPercent(c.started_at);
    const right = toPercent(c.ended_at);
    const color = c.location_category
      ? (CATEGORY_COLORS[c.location_category] || EMPTY_COLOR)
      : EMPTY_COLOR;
    segments.push({ left, width: right - left, color });
  }

  // Trips
  for (const t of day.trips) {
    const left = toPercent(t.started_at);
    const right = toPercent(t.ended_at);
    segments.push({ left, width: right - left, color: TRIP_COLOR });
  }

  const dateLabel = format(parseISO(day.date), 'EEE d MMM', { locale: fr });

  return (
    <div
      className={`flex items-center gap-3 cursor-pointer rounded-md px-2 py-1 ${isSelected ? 'bg-blue-50 ring-2 ring-blue-400' : 'hover:bg-slate-50'}`}
      onClick={onClick}
    >
      <span className="w-28 shrink-0 text-xs text-slate-500">
        {dateLabel} ({formatHours(day.shift_minutes)})
      </span>
      <div className="relative h-6 flex-1 rounded bg-slate-100 overflow-hidden">
        {segments.map((seg, i) => (
          <div
            key={i}
            className="absolute top-0 h-full"
            style={{
              left: `${seg.left}%`,
              width: `${Math.max(seg.width, 0.5)}%`,
              backgroundColor: seg.color,
              opacity: 0.7,
            }}
          />
        ))}
      </div>
    </div>
  );
}

export default function EmployeeUtilizationDetailPage() {
  const params = useParams();
  const searchParams = useSearchParams();
  const employeeId = params.employeeId as string;

  const fromParam = searchParams.get('from');
  const toParam = searchParams.get('to');

  const [dateFrom, setDateFrom] = useState(() =>
    fromParam ? new Date(fromParam + 'T00:00:00') : subDays(new Date(), 7)
  );
  const [dateTo, setDateTo] = useState(() =>
    toParam ? new Date(toParam + 'T00:00:00') : new Date()
  );
  const [selectedDate, setSelectedDate] = useState<string | null>(null);

  const { data, isLoading } = useEmployeeUtilizationDetail({
    employeeId,
    dateFrom,
    dateTo,
  });

  const filteredClusters = useMemo(() => {
    if (!data) return [];
    const days = selectedDate
      ? data.days.filter((d) => d.date === selectedDate)
      : data.days;
    return days.flatMap((d) =>
      d.clusters.map((c) => ({ ...c, date: d.date }))
    );
  }, [data, selectedDate]);

  const clusterStats = useMemo(() => {
    const total = filteredClusters.length;
    const matches = filteredClusters.filter((c) => c.match === true).length;
    const mismatches = filteredClusters.filter((c) => c.match === false).length;
    return { total, matches, mismatches };
  }, [filteredClusters]);

  const backHref = `/dashboard/reports/cleaning-utilization?from=${toLocalDateString(dateFrom)}&to=${toLocalDateString(dateTo)}`;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <Button variant="ghost" size="sm" asChild>
              <Link href={backHref}>
                <ArrowLeft className="h-4 w-4 mr-1" />
                Retour
              </Link>
            </Button>
          </div>
          <h1 className="text-2xl font-bold text-slate-900">
            {data?.employeeName ?? 'Chargement...'}
          </h1>
          {data?.summary && (
            <div className="mt-1 flex flex-wrap gap-4 text-sm text-slate-500">
              <span>{data.summary.total_shifts} shifts</span>
              <span>Utilisation: <PercentBar value={data.summary.utilization_pct} thresholds={{ green: 80, yellow: 60 }} /></span>
              <span>Accuracy: <PercentBar value={data.summary.accuracy_pct} thresholds={{ green: 90, yellow: 70 }} /></span>
              <span>{formatHours(data.summary.total_shift_minutes)} total</span>
            </div>
          )}
        </div>
        <div className="flex gap-2">
          <input type="date" className="rounded-md border border-slate-300 px-3 py-2 text-sm"
            value={toLocalDateString(dateFrom)}
            onChange={(e) => { setDateFrom(new Date(e.target.value + 'T00:00:00')); setSelectedDate(null); }} />
          <input type="date" className="rounded-md border border-slate-300 px-3 py-2 text-sm"
            value={toLocalDateString(dateTo)}
            onChange={(e) => { setDateTo(new Date(e.target.value + 'T00:00:00')); setSelectedDate(null); }} />
        </div>
      </div>

      {isLoading ? (
        <div className="py-12 text-center text-sm text-slate-400">Chargement...</div>
      ) : !data || data.days.length === 0 ? (
        <div className="py-12 text-center text-sm text-slate-400">Aucune donnee pour la periode selectionnee</div>
      ) : (
        <>
          {/* Timeline */}
          <Card>
            <CardHeader>
              <CardTitle className="text-lg">Timeline par jour</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="space-y-1">
                {data.days.map((day) => (
                  <DayTimeline
                    key={day.shift_id}
                    day={day}
                    isSelected={selectedDate === day.date}
                    onClick={() => setSelectedDate(
                      selectedDate === day.date ? null : day.date
                    )}
                  />
                ))}
              </div>
              <div className="mt-4 flex flex-wrap gap-4 text-xs text-slate-400">
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.match, opacity: 0.7 }} />Au bon endroit</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.mismatch, opacity: 0.7 }} />Mauvais endroit</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.office, opacity: 0.7 }} />Bureau</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.home, opacity: 0.7 }} />Domicile</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: TRIP_COLOR, opacity: 0.7 }} />Deplacement</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: EMPTY_COLOR }} />Pas de session</span>
              </div>
              <p className="mt-2 text-xs text-slate-400">Cliquez sur un jour pour filtrer le tableau</p>
            </CardContent>
          </Card>

          {/* Cluster detail table */}
          <Card>
            <CardHeader>
              <div className="flex items-center justify-between">
                <CardTitle className="text-lg">
                  Detail des clusters{selectedDate ? ` — ${format(parseISO(selectedDate), 'd MMM', { locale: fr })}` : ''}
                </CardTitle>
                <span className="text-sm text-slate-500">
                  {clusterStats.total} clusters · {clusterStats.matches} match · {clusterStats.mismatches} mismatch
                </span>
              </div>
            </CardHeader>
            <CardContent>
              {filteredClusters.length === 0 ? (
                <div className="py-8 text-center text-sm text-slate-400">Aucun cluster</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b text-left text-xs font-medium uppercase text-slate-500">
                        <th className="pb-3 pr-4">Heure</th>
                        <th className="pb-3 pr-4">Lieu physique</th>
                        <th className="pb-3 pr-4">Session declaree</th>
                        <th className="pb-3 pr-4 text-center">Match</th>
                        <th className="pb-3 text-right">Duree</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredClusters.map((c, i) => {
                        const isMismatch = c.match === false;
                        return (
                          <tr key={i} className={`border-b last:border-0 ${isMismatch ? 'bg-red-50' : ''}`}>
                            <td className="py-3 pr-4 text-slate-600">
                              {format(parseISO(c.started_at), 'HH:mm')} - {format(parseISO(c.ended_at), 'HH:mm')}
                            </td>
                            <td className="py-3 pr-4 font-medium">{c.physical_location}</td>
                            <td className="py-3 pr-4 text-slate-600">{c.session_building ?? '—'}</td>
                            <td className="py-3 pr-4 text-center">
                              {c.match === true && <span className="text-emerald-600 font-bold">✓</span>}
                              {c.match === false && <span className="text-red-600 font-bold">✗</span>}
                              {c.match === null && c.location_category === 'office' && <span className="text-blue-600 font-bold">🏢</span>}
                              {c.match === null && c.location_category === 'home' && <span className="text-purple-600 font-bold">🏠</span>}
                              {c.match === null && c.location_category === null && <span className="text-slate-400">—</span>}
                            </td>
                            <td className="py-3 text-right">{c.duration_minutes} min</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/app/dashboard/reports/cleaning-utilization/\[employeeId\]/page.tsx
git commit -m "feat(dashboard): add employee utilization detail page

Timeline per day with color-coded clusters/trips + detail table
with location match indicators."
```

---

## Task 4: Link from main report

**Files:**
- Modify: `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx`

- [ ] **Step 1: Add Link import and modify employee name cell**

In `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx`:

Add `import Link from 'next/link';` at the top.

Change the employee name `<td>`:
```tsx
// FROM:
<td className="py-3 pr-4 font-medium">
  {emp.employee_name}
</td>

// TO:
<td className="py-3 pr-4 font-medium">
  <Link
    href={`/dashboard/reports/cleaning-utilization/${emp.employee_id}?from=${toLocalDateString(dateFrom)}&to=${toLocalDateString(dateTo)}`}
    className="text-blue-600 hover:underline"
  >
    {emp.employee_name}
  </Link>
</td>
```

Also do the same for the `from`/`to` query params on page load — read them from `useSearchParams()` to persist the date range when navigating back. Add to the page component:

```tsx
import { useSearchParams } from 'next/navigation';

// Inside component, before useState declarations:
const searchParams = useSearchParams();
const fromParam = searchParams.get('from');
const toParam = searchParams.get('to');

// Update the useState initializers:
const [dateFrom, setDateFrom] = useState(() =>
  fromParam ? new Date(fromParam + 'T00:00:00') : subDays(new Date(), 7)
);
const [dateTo, setDateTo] = useState(() =>
  toParam ? new Date(toParam + 'T00:00:00') : new Date()
);
```

- [ ] **Step 2: Verify build**

```bash
cd dashboard && npx tsc --noEmit 2>&1 | grep -E "cleaning-utilization|employee-utilization"
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx
git commit -m "feat(dashboard): link employee names to detail page

Passes dateFrom/dateTo as query params, reads them back on return."
```

---

## Task 5: Integration test

- [ ] **Step 1: Test RPC returns valid data**

```sql
SELECT jsonb_array_length(r->'days') AS day_count,
  r->>'employee_name' AS name,
  r->'summary'->>'utilization_pct' AS util
FROM get_employee_utilization_detail(
  (SELECT id FROM employee_profiles WHERE full_name = 'Rostang Noumi'),
  '2026-03-11'::date, '2026-03-18'::date
) r;
```

- [ ] **Step 2: Verify dashboard builds and pages load**

```bash
cd dashboard && npm run dev
```

Navigate to cleaning-utilization report, click on an employee name → detail page should load with timeline and cluster table.

- [ ] **Step 3: Final commit if fixes needed**

```bash
git add -A && git commit -m "fix: polish employee utilization detail"
```
