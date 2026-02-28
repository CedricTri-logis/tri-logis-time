# Activity Timeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the separate Trajets and Arrêts tabs in the Kilométrage page with a unified "Activité" tab showing an employee's trips and stops in chronological order, with both table and vertical timeline views.

**Architecture:** New Supabase RPC (`get_employee_activity`) returns trips + stationary clusters merged and sorted by `started_at` via UNION ALL. The frontend replaces two TabsContent blocks with a single `ActivityTab` component that has employee/date/type filters, a view toggle (table/timeline), and expandable rows reusing existing map components (GoogleTripRouteMap for trips, StationaryClustersMap detail for stops).

**Tech Stack:** Next.js 14+ (App Router), Supabase RPC (PostgreSQL), shadcn/ui, Tailwind CSS, @vis.gl/react-google-maps, lucide-react

---

## Task 1: Create the `get_employee_activity` RPC (migration 077)

**Files:**
- Create: `supabase/migrations/077_get_employee_activity.sql`

**Step 1: Write the migration SQL**

```sql
-- Migration: get_employee_activity
-- Unified RPC returning trips + stationary clusters in chronological order

CREATE OR REPLACE FUNCTION get_employee_activity(
    p_employee_id UUID,
    p_date_from DATE,
    p_date_to DATE,
    p_type TEXT DEFAULT 'all',
    p_min_duration_seconds INTEGER DEFAULT 300
)
RETURNS TABLE (
    activity_type TEXT,
    id UUID,
    shift_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    -- Trip fields (NULL for stops)
    start_latitude DECIMAL,
    start_longitude DECIMAL,
    start_address TEXT,
    start_location_id UUID,
    start_location_name TEXT,
    end_latitude DECIMAL,
    end_longitude DECIMAL,
    end_address TEXT,
    end_location_id UUID,
    end_location_name TEXT,
    distance_km DECIMAL,
    road_distance_km DECIMAL,
    duration_minutes INTEGER,
    transport_mode TEXT,
    match_status TEXT,
    match_confidence DECIMAL,
    route_geometry TEXT,
    start_cluster_id UUID,
    end_cluster_id UUID,
    classification TEXT,
    gps_point_count INTEGER,
    -- Stop fields (NULL for trips)
    centroid_latitude DECIMAL,
    centroid_longitude DECIMAL,
    centroid_accuracy DECIMAL,
    duration_seconds INTEGER,
    cluster_gps_point_count INTEGER,
    matched_location_id UUID,
    matched_location_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH trip_data AS (
        SELECT
            'trip'::TEXT AS v_type,
            t.id,
            t.shift_id,
            t.started_at,
            t.ended_at,
            t.start_latitude,
            t.start_longitude,
            t.start_address,
            t.start_location_id,
            sl.name::TEXT AS start_location_name,
            t.end_latitude,
            t.end_longitude,
            t.end_address,
            t.end_location_id,
            el.name::TEXT AS end_location_name,
            t.distance_km,
            t.road_distance_km,
            t.duration_minutes,
            t.transport_mode::TEXT,
            t.match_status::TEXT,
            t.match_confidence,
            t.route_geometry,
            t.start_cluster_id,
            t.end_cluster_id,
            t.classification::TEXT,
            t.gps_point_count,
            -- Stop fields as NULL
            NULL::DECIMAL AS centroid_latitude,
            NULL::DECIMAL AS centroid_longitude,
            NULL::DECIMAL AS centroid_accuracy,
            NULL::INTEGER AS duration_seconds,
            NULL::INTEGER AS cluster_gps_point_count,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS matched_location_name
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date_from::TIMESTAMPTZ
          AND t.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND (p_type = 'all' OR p_type = 'trips')
    ),
    stop_data AS (
        SELECT
            'stop'::TEXT AS v_type,
            sc.id,
            sc.shift_id,
            sc.started_at,
            sc.ended_at,
            -- Trip fields as NULL
            NULL::DECIMAL AS start_latitude,
            NULL::DECIMAL AS start_longitude,
            NULL::TEXT AS start_address,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::DECIMAL AS end_latitude,
            NULL::DECIMAL AS end_longitude,
            NULL::TEXT AS end_address,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::INTEGER AS duration_minutes,
            NULL::TEXT AS transport_mode,
            NULL::TEXT AS match_status,
            NULL::DECIMAL AS match_confidence,
            NULL::TEXT AS route_geometry,
            NULL::UUID AS start_cluster_id,
            NULL::UUID AS end_cluster_id,
            NULL::TEXT AS classification,
            NULL::INTEGER AS gps_point_count,
            -- Stop fields
            sc.centroid_latitude,
            sc.centroid_longitude,
            sc.centroid_accuracy,
            sc.duration_seconds,
            sc.gps_point_count AS cluster_gps_point_count,
            sc.matched_location_id,
            l.name::TEXT AS matched_location_name
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date_from::TIMESTAMPTZ
          AND sc.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= p_min_duration_seconds
          AND (p_type = 'all' OR p_type = 'stops')
    )
    SELECT
        td.v_type,
        td.id,
        td.shift_id,
        td.started_at,
        td.ended_at,
        td.start_latitude,
        td.start_longitude,
        td.start_address,
        td.start_location_id,
        td.start_location_name,
        td.end_latitude,
        td.end_longitude,
        td.end_address,
        td.end_location_id,
        td.end_location_name,
        td.distance_km,
        td.road_distance_km,
        td.duration_minutes,
        td.transport_mode,
        td.match_status,
        td.match_confidence,
        td.route_geometry,
        td.start_cluster_id,
        td.end_cluster_id,
        td.classification,
        td.gps_point_count,
        td.centroid_latitude,
        td.centroid_longitude,
        td.centroid_accuracy,
        td.duration_seconds,
        td.cluster_gps_point_count,
        td.matched_location_id,
        td.matched_location_name
    FROM (
        SELECT * FROM trip_data
        UNION ALL
        SELECT * FROM stop_data
    ) td
    ORDER BY td.started_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

Or apply via MCP: `apply_migration(project_id, "get_employee_activity", <sql>)`

**Step 3: Test the RPC**

Run via Supabase SQL editor or `execute_sql`:
```sql
SELECT * FROM get_employee_activity(
    '<some_employee_id>',
    '2026-02-27',
    '2026-02-27'
) LIMIT 20;
```

Expected: Rows with alternating `activity_type` values ('trip' and 'stop'), sorted by `started_at` ASC.

**Step 4: Commit**

```bash
git add supabase/migrations/077_get_employee_activity.sql
git commit -m "feat: add get_employee_activity RPC (migration 077)"
```

---

## Task 2: Add TypeScript types for ActivityItem

**Files:**
- Modify: `dashboard/src/types/mileage.ts`

**Step 1: Add the ActivityItem types**

Add at the end of `dashboard/src/types/mileage.ts`:

```typescript
// Activity timeline types (unified trips + stops)
export interface ActivityItemBase {
  activity_type: 'trip' | 'stop';
  id: string;
  shift_id: string;
  started_at: string;
  ended_at: string;
}

export interface ActivityTrip extends ActivityItemBase {
  activity_type: 'trip';
  start_latitude: number;
  start_longitude: number;
  start_address: string | null;
  start_location_id: string | null;
  start_location_name: string | null;
  end_latitude: number;
  end_longitude: number;
  end_address: string | null;
  end_location_id: string | null;
  end_location_name: string | null;
  distance_km: number;
  road_distance_km: number | null;
  duration_minutes: number;
  transport_mode: 'driving' | 'walking' | 'unknown';
  match_status: 'pending' | 'processing' | 'matched' | 'failed' | 'anomalous';
  match_confidence: number | null;
  route_geometry: string | null;
  start_cluster_id: string | null;
  end_cluster_id: string | null;
  classification: 'business' | 'personal';
  gps_point_count: number;
}

export interface ActivityStop extends ActivityItemBase {
  activity_type: 'stop';
  centroid_latitude: number;
  centroid_longitude: number;
  centroid_accuracy: number | null;
  duration_seconds: number;
  cluster_gps_point_count: number;
  matched_location_id: string | null;
  matched_location_name: string | null;
}

export type ActivityItem = ActivityTrip | ActivityStop;
```

**Step 2: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add ActivityItem types for unified timeline"
```

---

## Task 3: Create the ActivityTab component — filters and data fetching

**Files:**
- Create: `dashboard/src/components/mileage/activity-tab.tsx`

**Step 1: Create the component with filters and fetch logic**

Create `dashboard/src/components/mileage/activity-tab.tsx`:

```tsx
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Loader2,
  Car,
  Footprints,
  MapPin,
  ChevronLeft,
  ChevronRight,
  List,
  Clock,
} from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import type { ActivityItem, ActivityTrip, ActivityStop } from '@/types/mileage';

type TypeFilter = 'all' | 'trips' | 'stops';
type ViewMode = 'table' | 'timeline';

interface Employee {
  id: string;
  full_name: string;
}

function formatDate(date: Date): string {
  return date.toISOString().split('T')[0];
}

function formatTime(dateStr: string): string {
  return new Date(dateStr).toLocaleTimeString('fr-CA', {
    hour: '2-digit',
    minute: '2-digit',
  });
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, '0')}min`;
  return `${minutes} min`;
}

function formatDurationMinutes(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  if (hours > 0) return `${hours}h ${mins.toString().padStart(2, '0')}min`;
  return `${mins} min`;
}

function formatDateHeader(dateStr: string): string {
  const date = new Date(dateStr);
  return date.toLocaleDateString('fr-CA', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });
}

export function ActivityTab() {
  // Filter state
  const [selectedEmployee, setSelectedEmployee] = useState<string>('');
  const [dateFrom, setDateFrom] = useState<string>(formatDate(new Date()));
  const [dateTo, setDateTo] = useState<string>(formatDate(new Date()));
  const [isRangeMode, setIsRangeMode] = useState(false);
  const [typeFilter, setTypeFilter] = useState<TypeFilter>('all');
  const [minDuration, setMinDuration] = useState(300);
  const [viewMode, setViewMode] = useState<ViewMode>('table');

  // Data state
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [activities, setActivities] = useState<ActivityItem[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Expand state
  const [expandedId, setExpandedId] = useState<string | null>(null);

  // Fetch employees on mount
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name')
        .order('full_name');
      if (data) setEmployees(data as Employee[]);
    })();
  }, []);

  // Effective date range (single day or range)
  const effectiveDateTo = isRangeMode ? dateTo : dateFrom;

  // Fetch activity data
  const fetchActivity = useCallback(async () => {
    if (!selectedEmployee) return;
    setIsLoading(true);
    setError(null);
    try {
      const { data, error: rpcError } = await supabaseClient.rpc(
        'get_employee_activity',
        {
          p_employee_id: selectedEmployee,
          p_date_from: dateFrom,
          p_date_to: effectiveDateTo,
          p_type: typeFilter,
          p_min_duration_seconds: minDuration,
        }
      );

      if (rpcError) {
        setError(rpcError.message);
        setActivities([]);
        return;
      }

      setActivities((data as ActivityItem[]) || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
      setActivities([]);
    } finally {
      setIsLoading(false);
    }
  }, [selectedEmployee, dateFrom, effectiveDateTo, typeFilter, minDuration]);

  useEffect(() => {
    fetchActivity();
  }, [fetchActivity]);

  // Navigate day by day
  const navigateDay = (direction: -1 | 1) => {
    const current = new Date(dateFrom);
    current.setDate(current.getDate() + direction);
    const newDate = formatDate(current);
    setDateFrom(newDate);
    if (!isRangeMode) setDateTo(newDate);
  };

  // Stats
  const stats = useMemo(() => {
    const trips = activities.filter((a): a is ActivityTrip => a.activity_type === 'trip');
    const stops = activities.filter((a): a is ActivityStop => a.activity_type === 'stop');
    const totalDistanceGps = trips.reduce((sum, t) => sum + (t.distance_km || 0), 0);
    const totalDistanceRoute = trips.reduce((sum, t) => sum + (t.road_distance_km || 0), 0);
    const totalTravelSeconds = trips.reduce((sum, t) => sum + (t.duration_minutes || 0) * 60, 0);
    const totalStopSeconds = stops.reduce((sum, t) => sum + (t.duration_seconds || 0), 0);
    return {
      total: activities.length,
      tripCount: trips.length,
      stopCount: stops.length,
      totalDistanceGps,
      totalDistanceRoute,
      totalTravelSeconds,
      totalStopSeconds,
    };
  }, [activities]);

  // Group by day (for range mode + timeline)
  const groupedByDay = useMemo(() => {
    const groups: Record<string, ActivityItem[]> = {};
    for (const item of activities) {
      const day = item.started_at.split('T')[0];
      if (!groups[day]) groups[day] = [];
      groups[day].push(item);
    }
    return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
  }, [activities]);

  return (
    <div className="space-y-4">
      {/* Filter bar */}
      <Card>
        <CardContent className="pt-4 pb-4">
          <div className="flex flex-wrap items-end gap-4">
            {/* Employee selector */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Employé</label>
              <select
                className="border rounded-md px-3 py-1.5 text-sm bg-background"
                value={selectedEmployee}
                onChange={(e) => setSelectedEmployee(e.target.value)}
              >
                <option value="">Sélectionner un employé</option>
                {employees.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name || emp.id}
                  </option>
                ))}
              </select>
            </div>

            {/* Date navigation */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date</label>
              <div className="flex items-center gap-1">
                {!isRangeMode && (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={() => navigateDay(-1)}
                  >
                    <ChevronLeft className="h-4 w-4" />
                  </Button>
                )}
                <input
                  type="date"
                  className="border rounded-md px-3 py-1.5 text-sm bg-background"
                  value={dateFrom}
                  onChange={(e) => {
                    setDateFrom(e.target.value);
                    if (!isRangeMode) setDateTo(e.target.value);
                  }}
                />
                {isRangeMode && (
                  <>
                    <span className="text-sm text-muted-foreground px-1">→</span>
                    <input
                      type="date"
                      className="border rounded-md px-3 py-1.5 text-sm bg-background"
                      value={dateTo}
                      onChange={(e) => setDateTo(e.target.value)}
                    />
                  </>
                )}
                {!isRangeMode && (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={() => navigateDay(1)}
                  >
                    <ChevronRight className="h-4 w-4" />
                  </Button>
                )}
              </div>
            </div>

            {/* Range toggle */}
            <Button
              variant={isRangeMode ? 'default' : 'outline'}
              size="sm"
              onClick={() => {
                setIsRangeMode(!isRangeMode);
                if (isRangeMode) setDateTo(dateFrom);
              }}
            >
              Plage
            </Button>

            {/* Type filter chips */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Type</label>
              <div className="flex gap-1">
                {(['all', 'trips', 'stops'] as TypeFilter[]).map((t) => (
                  <Button
                    key={t}
                    variant={typeFilter === t ? 'default' : 'outline'}
                    size="sm"
                    onClick={() => setTypeFilter(t)}
                  >
                    {t === 'all' ? 'Tout' : t === 'trips' ? 'Trajets' : 'Arrêts'}
                  </Button>
                ))}
              </div>
            </div>

            {/* Min duration (only for stops) */}
            {(typeFilter === 'all' || typeFilter === 'stops') && (
              <div className="flex flex-col gap-1">
                <label className="text-xs font-medium text-muted-foreground">
                  Durée min arrêts
                </label>
                <select
                  className="border rounded-md px-3 py-1.5 text-sm bg-background"
                  value={minDuration}
                  onChange={(e) => setMinDuration(Number(e.target.value))}
                >
                  <option value={180}>3 min</option>
                  <option value={300}>5 min</option>
                  <option value={600}>10 min</option>
                  <option value={900}>15 min</option>
                  <option value={1800}>30 min</option>
                </select>
              </div>
            )}

            {/* View toggle */}
            <div className="flex flex-col gap-1 ml-auto">
              <label className="text-xs font-medium text-muted-foreground">Vue</label>
              <div className="flex gap-1">
                <Button
                  variant={viewMode === 'table' ? 'default' : 'outline'}
                  size="icon"
                  className="h-8 w-8"
                  onClick={() => setViewMode('table')}
                  title="Tableau"
                >
                  <List className="h-4 w-4" />
                </Button>
                <Button
                  variant={viewMode === 'timeline' ? 'default' : 'outline'}
                  size="icon"
                  className="h-8 w-8"
                  onClick={() => setViewMode('timeline')}
                  title="Timeline"
                >
                  <Clock className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Stats bar */}
      {selectedEmployee && !isLoading && activities.length > 0 && (
        <div className="flex items-center gap-4 text-sm text-muted-foreground px-1">
          <span>{stats.total} événements</span>
          <span className="text-blue-600">{stats.tripCount} trajets</span>
          <span className="text-green-600">{stats.stopCount} arrêts</span>
          <span>|</span>
          <span>
            {stats.totalDistanceGps.toFixed(1)} km GPS
            {stats.totalDistanceRoute > 0 &&
              ` / ${stats.totalDistanceRoute.toFixed(1)} km route`}
          </span>
          <span>|</span>
          <span>
            {formatDuration(stats.totalTravelSeconds)} en déplacement /{' '}
            {formatDuration(stats.totalStopSeconds)} en arrêt
          </span>
        </div>
      )}

      {/* Empty state */}
      {!selectedEmployee && (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Sélectionnez un employé pour voir son activité
          </CardContent>
        </Card>
      )}

      {/* Loading */}
      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">{error}</div>
      )}

      {/* No results */}
      {selectedEmployee && !isLoading && !error && activities.length === 0 && (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Aucune activité trouvée pour cette période
          </CardContent>
        </Card>
      )}

      {/* Table view */}
      {selectedEmployee && !isLoading && activities.length > 0 && viewMode === 'table' && (
        <ActivityTable
          activities={activities}
          groupedByDay={groupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
        />
      )}

      {/* Timeline view */}
      {selectedEmployee && !isLoading && activities.length > 0 && viewMode === 'timeline' && (
        <ActivityTimeline
          activities={activities}
          groupedByDay={groupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
        />
      )}
    </div>
  );
}
```

**Note:** `ActivityTable` and `ActivityTimeline` components are created in subsequent tasks. For now, create stub exports at the bottom of this file:

```tsx
// Stubs — replaced in Tasks 4 and 5
function ActivityTable(props: any) {
  return <div>Table view placeholder</div>;
}

function ActivityTimeline(props: any) {
  return <div>Timeline view placeholder</div>;
}
```

**Step 2: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx dashboard/src/types/mileage.ts
git commit -m "feat: add ActivityTab component with filters and data fetching"
```

---

## Task 4: Create the ActivityTable component

**Files:**
- Modify: `dashboard/src/components/mileage/activity-tab.tsx` (replace ActivityTable stub)

**Step 1: Replace the ActivityTable stub**

Replace the `ActivityTable` stub function with the full implementation. This is a table inside a Card, with expandable rows. Reuse patterns from the existing `TripRow` (line 969 of `page.tsx`) for trip expand, and from `StationaryClustersTab` for stop display.

The table columns: Type (icon), Début (HH:mm), Fin (HH:mm), Durée, Détails (route or location name), Distance, Statut.

When a trip row is expanded:
- Fetch GPS points via `trip_gps_points` → `gps_points` (same pattern as TripRow lines 996-1033)
- Show `GoogleTripRouteMap` + trip details grid
- Show `LocationPickerDropdown` for start/end location reassignment

When a stop row is expanded:
- Fetch cluster GPS points via RPC `get_cluster_gps_points`
- Show a simple Google Map with the cluster centroid and GPS point markers
- Show stop details (location, duration, GPS point count, accuracy)

**Key patterns to follow:**
- Each row is its own sub-component (`ActivityTableRow`) that manages its own GPS point fetching on expand
- Import `GoogleTripRouteMap` from `@/components/trips/google-trip-route-map`
- Import `LocationPickerDropdown` from `@/components/trips/location-picker-dropdown`
- Import `MatchStatusBadge` from `@/components/trips/match-status-badge`
- Import `detectTripStops`, `detectGpsClusters` from `@/lib/utils/detect-trip-stops`
- For stop GPS detail, use `StationaryClustersMap` with a single cluster passed in, or build a simpler inline map

**In range mode**, add day separator rows (`<tr>` with colspan and bold date header) using `groupedByDay`.

**Step 2: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx
git commit -m "feat: add ActivityTable with expandable trip/stop rows"
```

---

## Task 5: Create the ActivityTimeline component

**Files:**
- Modify: `dashboard/src/components/mileage/activity-tab.tsx` (replace ActivityTimeline stub)

**Step 1: Replace the ActivityTimeline stub**

The timeline is a vertical stack of cards connected by a line. Structure:

```
<div className="relative pl-8">
  {/* Vertical line */}
  <div className="absolute left-3 top-0 bottom-0 w-0.5 bg-border" />

  {activities.map((item) => (
    <div key={item.id} className="relative mb-4">
      {/* Dot on the line */}
      <div className={`absolute left-[-20px] top-4 w-3 h-3 rounded-full border-2 border-background ${colorClass}`} />

      {/* Card */}
      <Card className={`cursor-pointer border-l-4 ${borderColorClass}`} onClick={...}>
        <CardContent className="py-3 px-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              {icon}
              <span className="font-medium">{formatTime(item.started_at)}</span>
              <span className="text-muted-foreground">→ {formatTime(item.ended_at)}</span>
              <span className="text-muted-foreground">({duration})</span>
            </div>
            <div>{details}</div>
          </div>
        </CardContent>
      </Card>

      {/* Expanded detail (same as table expand) */}
      {expandedId === item.id && <ExpandedDetail />}
    </div>
  ))}
</div>
```

**Colors:**
- Trip (driving): `border-l-blue-500`, dot `bg-blue-500`
- Trip (walking): `border-l-orange-500`, dot `bg-orange-500`
- Stop (matched): `border-l-green-500`, dot `bg-green-500`
- Stop (unmatched): `border-l-amber-500`, dot `bg-amber-500`

**Range mode:** Add day separator headers between day groups:
```tsx
<div className="flex items-center gap-2 mb-2 mt-6 first:mt-0">
  <div className="h-0.5 flex-1 bg-border" />
  <span className="text-sm font-semibold text-muted-foreground">{formatDateHeader(day)}</span>
  <div className="h-0.5 flex-1 bg-border" />
</div>
```

The expand detail reuses the same expand component as ActivityTable (extract into a shared `ActivityExpandedDetail` component if needed, or inline both).

**Step 2: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx
git commit -m "feat: add ActivityTimeline vertical card view"
```

---

## Task 6: Wire ActivityTab into the mileage page and move batch actions

**Files:**
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Update imports**

Add at top of `page.tsx`:
```typescript
import { ActivityTab } from '@/components/mileage/activity-tab';
```

Remove the now-unused import:
```typescript
// Remove: import { StationaryClustersTab } from '@/components/mileage/stationary-clusters-tab';
```

**Step 2: Replace tabs**

In the TabsList (lines 529-534), replace:
```tsx
<TabsTrigger value="trips">Trajets</TabsTrigger>
<TabsTrigger value="clusters">Arrêts</TabsTrigger>
```
with:
```tsx
<TabsTrigger value="activity">Activité</TabsTrigger>
```

Add the new TabsContent after the TabsList:
```tsx
<TabsContent value="activity" className="mt-4">
  <ActivityTab />
</TabsContent>
```

Remove the old TabsContent for "trips" (lines 536-951) and "clusters" (lines 953-955).

**Step 3: Move batch actions to global dropdown**

Move the batch action card (lines 538-594) out of the trips TabsContent and place it **above** the Tabs component as a global action area. Convert it to a dropdown menu using shadcn `DropdownMenu`:

```tsx
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { Settings } from 'lucide-react';
```

Place before `<Tabs>`:
```tsx
<div className="flex justify-between items-center">
  <h1 className="text-2xl font-bold">Kilométrage</h1>
  <DropdownMenu>
    <DropdownMenuTrigger asChild>
      <Button variant="outline" disabled={isProcessing}>
        <Settings className="h-4 w-4 mr-2" />
        Actions
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent align="end">
      <DropdownMenuItem onClick={handleProcessPending} disabled={isProcessing}>
        Traiter les en attente
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => openDialog('failed')} disabled={isProcessing}>
        Retraiter les trajets échoués
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => openDialog('all')} disabled={isProcessing}>
        Retraiter tous les trajets
      </DropdownMenuItem>
      <DropdownMenuItem onClick={handleRematchLocations} disabled={isRematching}>
        Re-match emplacements
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</div>
```

Keep the batch processing functions (`handleProcessPending`, `handleRematchLocations`, `openDialog`, etc.) and the Dialog component in page.tsx — they still work the same way, just triggered from the global dropdown instead of inline buttons.

**Step 4: Update default tab**

Change the default tab state:
```typescript
const [activeTab, setActiveTab] = useState('activity'); // was 'trips'
```

**Step 5: Clean up unused state**

Remove state variables and functions that were only used by the old trips tab:
- `trips`, `isLoadingTrips`, `tripsError` — the ActivityTab manages its own data
- `sortField`, `sortOrder`, `statusFilter`, `modeFilter`, `carpoolFilter` — filtering is now in ActivityTab
- `expandedTrip` — ActivityTab manages its own expand state
- `carpoolByTripId`, `vehiclePeriods` — data fetching is now in ActivityTab
- `fetchTrips`, `fetchCarpoolData`, `fetchVehiclePeriods` functions
- `filteredTrips`, `sortedTrips` memos
- `getVehicleForTrip` helper
- `stats` memo (the old match status stats)
- The entire `TripRow` component definition (lines 969-1249)

Keep: `isProcessing`, `showDialog`, `dialogMode`, `batchResult`, `batchError`, `isRematching` — these are for the batch actions which remain in page.tsx.

**Step 6: Verify the page still renders**

Run: `cd dashboard && npm run dev`

Navigate to `/dashboard/mileage`. Verify:
- "Activité" tab is the default and shows the filter bar
- Véhicules and Covoiturages tabs still work
- Global "Actions" dropdown is visible and functional
- No console errors

**Step 7: Commit**

```bash
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: replace Trajets/Arrêts tabs with unified Activité tab"
```

---

## Task 7: Polish and edge cases

**Files:**
- Modify: `dashboard/src/components/mileage/activity-tab.tsx`

**Step 1: Handle edge cases**

- When `dateFrom` equals today's date, disable the "next day" arrow (can't navigate to the future)
- When no activities are found and an employee is selected, show a helpful empty state with the date
- Ensure the expand detail for stops fetches GPS points via `get_cluster_gps_points` RPC and displays them properly
- Ensure the expand detail for trips fetches via `trip_gps_points` → `gps_points` join and shows the `GoogleTripRouteMap`

**Step 2: Verify end-to-end**

Run: `cd dashboard && npm run dev`

Test scenarios:
1. Select an employee, see today's activity
2. Navigate with < > arrows to see different days
3. Toggle range mode, select a week, see day separators
4. Filter "Trajets" only — see only trips (mileage review workflow)
5. Filter "Arrêts" only — see only stops
6. Switch to timeline view — see vertical cards with colored borders
7. Expand a trip row — see GPS map with route
8. Expand a stop row — see cluster centroid and GPS points
9. Use "Actions" dropdown — process pending, reprocess, rematch still work

**Step 3: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx
git commit -m "feat: polish activity tab edge cases and interactions"
```

---

## Summary

| Task | Description | Estimated complexity |
|------|-------------|---------------------|
| 1 | RPC migration `get_employee_activity` | Backend SQL |
| 2 | TypeScript `ActivityItem` types | Tiny |
| 3 | `ActivityTab` — filters, fetch, stats, layout | Core component |
| 4 | `ActivityTable` — table view with expandable rows | UI heavy |
| 5 | `ActivityTimeline` — vertical timeline view | UI heavy |
| 6 | Wire into `page.tsx`, move batch actions, clean up | Integration |
| 7 | Polish and edge cases | QA |
