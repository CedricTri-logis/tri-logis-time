# GPS Gaps By Day Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Trous GPS par jour" section to the diagnostics page showing all GPS gaps ≥5min grouped by day then by employee, with inline period badges.

**Architecture:** One new RPC returns flat rows (day, employee, gap_start, gap_end, gap_minutes). Frontend groups by day → employee via useMemo. Collapsible day sections, today/yesterday expanded by default.

**Tech Stack:** Supabase RPC (plpgsql), React hook (useCustom), shadcn/ui components

---

## File Structure

```
supabase/migrations/
  20260320200000_get_gps_gaps_by_day.sql     # New RPC

dashboard/src/
  types/gps-diagnostics.ts                    # Add GpsGapByDayRow + GpsGapByDay types (modify)
  lib/hooks/use-gps-gaps-by-day.ts            # New hook
  components/diagnostics/gps-gaps-by-day.tsx   # New component
  app/dashboard/diagnostics/page.tsx           # Add section below incident feed (modify)
```

---

### Task 1: Create RPC `get_gps_gaps_by_day`

**Files:**
- Create: `supabase/migrations/20260320200000_get_gps_gaps_by_day.sql`

- [ ] **Step 1: Write migration**

```sql
-- Returns all GPS gaps >= threshold, flat rows for frontend grouping
CREATE OR REPLACE FUNCTION get_gps_gaps_by_day(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL,
    p_min_gap_minutes NUMERIC DEFAULT 5
)
RETURNS TABLE(
    day DATE,
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    shift_id UUID,
    gap_start TIMESTAMPTZ,
    gap_end TIMESTAMPTZ,
    gap_minutes NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH point_gaps AS (
    SELECT
      s.employee_id,
      gp.shift_id,
      (s.clocked_in_at AT TIME ZONE 'America/Montreal')::DATE AS shift_day,
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  )
  SELECT
    pg.shift_day AS day,
    pg.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    pg.shift_id,
    pg.prev_at AS gap_start,
    pg.captured_at AS gap_end,
    ROUND(EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0, 1) AS gap_minutes
  FROM point_gaps pg
  JOIN employee_profiles ep ON ep.id = pg.employee_id
  WHERE pg.prev_at IS NOT NULL
    AND EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0 >= p_min_gap_minutes
  ORDER BY pg.shift_day DESC, gap_minutes DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_gaps_by_day TO authenticated;
```

- [ ] **Step 2: Apply migration via MCP** `apply_migration` with project `xdyzdclwvhkfwbkrdsiz`, name `20260320200000_get_gps_gaps_by_day`

- [ ] **Step 3: Verify**

```sql
SELECT * FROM get_gps_gaps_by_day(now() - interval '3 days', now()) LIMIT 10;
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260320200000_get_gps_gaps_by_day.sql
git commit -m "feat: add get_gps_gaps_by_day RPC"
```

---

### Task 2: Add types + hook + component + integrate into page

**Files:**
- Modify: `dashboard/src/types/gps-diagnostics.ts` — add types at end
- Create: `dashboard/src/lib/hooks/use-gps-gaps-by-day.ts`
- Create: `dashboard/src/components/diagnostics/gps-gaps-by-day.tsx`
- Modify: `dashboard/src/app/dashboard/diagnostics/page.tsx` — add section

- [ ] **Step 1: Add types to `gps-diagnostics.ts`**

Append at end of file:

```typescript
// ---- GPS Gaps By Day (diagnostics section) ----

export interface GpsGapByDayRow {
  day: string;
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  shift_id: string;
  gap_start: string;
  gap_end: string;
  gap_minutes: number;
}

export interface GpsGapByDay {
  day: string;
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  shiftId: string;
  gapStart: Date;
  gapEnd: Date;
  gapMinutes: number;
}

export function transformGapByDayRow(row: GpsGapByDayRow): GpsGapByDay {
  return {
    day: row.day,
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    shiftId: row.shift_id,
    gapStart: new Date(row.gap_start),
    gapEnd: new Date(row.gap_end),
    gapMinutes: row.gap_minutes,
  };
}

// Grouped structure for the component
export interface GapsByDayGroup {
  day: string;
  totalGaps: number;
  totalEmployees: number;
  employees: GapsByEmployeeGroup[];
}

export interface GapsByEmployeeGroup {
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  gaps: { gapStart: Date; gapEnd: Date; gapMinutes: number }[];
  totalMinutes: number;
}
```

- [ ] **Step 2: Create hook**

Create `dashboard/src/lib/hooks/use-gps-gaps-by-day.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsGapByDayRow, GpsGapByDay, GapsByDayGroup, GapsByEmployeeGroup } from '@/types/gps-diagnostics';
import { transformGapByDayRow } from '@/types/gps-diagnostics';

export function useGpsGapsByDay(
  startDate: string,
  endDate: string,
  employeeId?: string | null,
  minGapMinutes: number = 5,
) {
  const { query, result } = useCustom<GpsGapByDayRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_gaps_by_day' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_min_gap_minutes: minGapMinutes,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsGapByDayRow[] | undefined;

  // Group flat rows into day → employee → gaps structure
  const grouped: GapsByDayGroup[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    const items = raw.map(transformGapByDayRow);

    const dayMap = new Map<string, Map<string, GpsGapByDay[]>>();

    for (const item of items) {
      if (!dayMap.has(item.day)) dayMap.set(item.day, new Map());
      const empMap = dayMap.get(item.day)!;
      if (!empMap.has(item.employeeId)) empMap.set(item.employeeId, []);
      empMap.get(item.employeeId)!.push(item);
    }

    const result: GapsByDayGroup[] = [];

    for (const [day, empMap] of dayMap) {
      const employees: GapsByEmployeeGroup[] = [];

      for (const [empId, gaps] of empMap) {
        const first = gaps[0];
        const totalMinutes = gaps.reduce((sum, g) => sum + g.gapMinutes, 0);
        employees.push({
          employeeId: empId,
          fullName: first.fullName,
          devicePlatform: first.devicePlatform,
          deviceModel: first.deviceModel,
          gaps: gaps
            .map((g) => ({ gapStart: g.gapStart, gapEnd: g.gapEnd, gapMinutes: g.gapMinutes }))
            .sort((a, b) => a.gapStart.getTime() - b.gapStart.getTime()),
          totalMinutes: Math.round(totalMinutes * 10) / 10,
        });
      }

      // Sort employees by total minutes descending
      employees.sort((a, b) => b.totalMinutes - a.totalMinutes);

      result.push({
        day,
        totalGaps: employees.reduce((sum, e) => sum + e.gaps.length, 0),
        totalEmployees: employees.length,
        employees,
      });
    }

    // Days already sorted DESC from RPC, but ensure it
    result.sort((a, b) => b.day.localeCompare(a.day));

    return result;
  }, [raw]);

  return {
    data: grouped,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
```

- [ ] **Step 3: Create component**

Create `dashboard/src/components/diagnostics/gps-gaps-by-day.tsx`:

```typescript
'use client';

import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { ChevronDown, ChevronRight } from 'lucide-react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { cn } from '@/lib/utils';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GapsByDayGroup } from '@/types/gps-diagnostics';

interface GpsGapsByDayProps {
  data: GapsByDayGroup[];
  isLoading: boolean;
}

export function GpsGapsByDay({ data, isLoading }: GpsGapsByDayProps) {
  // First 2 days expanded by default
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());

  const toggleDay = (day: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(day)) next.delete(day);
      else next.add(day);
      return next;
    });
  };

  if (isLoading) {
    return (
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {[...Array(3)].map((_, i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  if (data.length === 0) {
    return (
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
        </CardHeader>
        <CardContent className="py-8 text-center">
          <p className="text-sm text-slate-500">Aucun trou GPS ≥ 5 min pour cette période</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        {data.map((dayGroup, dayIdx) => {
          const isCollapsed = dayIdx >= 2 ? !collapsed.has(dayGroup.day) : collapsed.has(dayGroup.day);
          const dayDate = parseISO(dayGroup.day);

          return (
            <div key={dayGroup.day}>
              {/* Day header */}
              <button
                onClick={() => toggleDay(dayGroup.day)}
                className="flex w-full items-center gap-2 px-6 py-3 border-b border-slate-200 hover:bg-slate-50 cursor-pointer"
              >
                {isCollapsed ? (
                  <ChevronRight className="h-4 w-4 text-slate-400" />
                ) : (
                  <ChevronDown className="h-4 w-4 text-slate-400" />
                )}
                <span className="text-sm font-bold text-slate-900">
                  {format(dayDate, 'EEEE d MMMM', { locale: fr })}
                </span>
                <span className={cn(
                  'px-2 py-0.5 rounded-full text-xs font-medium',
                  dayGroup.totalGaps > 15 ? 'bg-red-100 text-red-800' : 'bg-amber-100 text-amber-800'
                )}>
                  {dayGroup.totalGaps} trou{dayGroup.totalGaps > 1 ? 's' : ''} · {dayGroup.totalEmployees} employé{dayGroup.totalEmployees > 1 ? 's' : ''}
                </span>
              </button>

              {/* Employees + gaps (collapsible) */}
              {!isCollapsed && (
                <div className="px-6">
                  {dayGroup.employees.map((emp) => (
                    <div key={emp.employeeId} className="py-3 border-b border-slate-100 last:border-0">
                      <div className="flex items-center gap-2 mb-2">
                        <span className="text-sm font-semibold text-slate-900 w-40 truncate">
                          {emp.fullName}
                        </span>
                        <span className="text-xs text-slate-500">
                          {emp.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(emp.deviceModel) ?? ''}
                        </span>
                        <span className={cn(
                          'ml-auto text-xs font-semibold',
                          emp.totalMinutes > 60 ? 'text-red-600' : 'text-amber-600'
                        )}>
                          {emp.gaps.length} trou{emp.gaps.length > 1 ? 's' : ''} · {emp.totalMinutes} min total
                        </span>
                      </div>
                      <div className="flex gap-1.5 flex-wrap pl-1">
                        {emp.gaps.map((gap, gapIdx) => (
                          <div
                            key={gapIdx}
                            className={cn(
                              'rounded-md border px-2.5 py-1 text-xs',
                              gap.gapMinutes >= 30
                                ? 'bg-red-50 border-red-200'
                                : 'bg-amber-50 border-amber-200'
                            )}
                          >
                            <span className={cn(
                              'font-semibold',
                              gap.gapMinutes >= 30 ? 'text-red-700' : 'text-amber-700'
                            )}>
                              {gap.gapMinutes} min
                            </span>
                            <span className="text-slate-500 ml-1.5">
                              {format(gap.gapStart, 'HH:mm')} → {format(gap.gapEnd, 'HH:mm')}
                            </span>
                          </div>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 4: Integrate into page**

In `dashboard/src/app/dashboard/diagnostics/page.tsx`:

Add import:
```typescript
import { useGpsGapsByDay } from '@/lib/hooks/use-gps-gaps-by-day';
import { GpsGapsByDay } from '@/components/diagnostics/gps-gaps-by-day';
```

Add hook call after the feed hook:
```typescript
const gapsByDay = useGpsGapsByDay(startDate, endDate, employeeFilter);
```

Add section after the GpsIncidentFeed:
```typescript
{/* GPS Gaps by Day */}
<GpsGapsByDay data={gapsByDay.data} isLoading={gapsByDay.isLoading} />
```

- [ ] **Step 5: Verify build**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npx tsc --noEmit && npm run build
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/types/gps-diagnostics.ts \
  dashboard/src/lib/hooks/use-gps-gaps-by-day.ts \
  dashboard/src/components/diagnostics/gps-gaps-by-day.tsx \
  dashboard/src/app/dashboard/diagnostics/page.tsx
git commit -m "feat: add GPS gaps by day section to diagnostics page"
```
