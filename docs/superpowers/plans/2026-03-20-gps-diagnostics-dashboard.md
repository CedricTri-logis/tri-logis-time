# GPS Diagnostics Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an admin-only GPS diagnostics page at `/dashboard/diagnostics` with real-time incident feed, KPIs, trend chart, employee ranking, and a detail drawer.

**Architecture:** 6 Supabase RPCs handle all data aggregation server-side (message classification, gap calculation, pagination). The Next.js dashboard consumes them via Refine `useCustom` hooks. Dense grid layout with recharts for the trend chart and a slide-in drawer for employee detail.

**Tech Stack:** Next.js 16 (App Router), Refine 5, shadcn/ui, recharts (new dep), Supabase RPCs (plpgsql), TypeScript 5.9

**Spec:** `docs/superpowers/specs/2026-03-20-gps-diagnostics-dashboard-design.md`

---

## File Structure

```
supabase/migrations/
  20260320000000_gps_diagnostics_rpcs.sql        # All 6 RPCs + helper function

dashboard/src/
  types/gps-diagnostics.ts                        # All TypeScript interfaces + transforms
  lib/hooks/use-gps-diagnostics-summary.ts        # KPI data hook
  lib/hooks/use-gps-diagnostics-trend.ts          # Chart data hook
  lib/hooks/use-gps-diagnostics-ranking.ts        # Employee ranking hook
  lib/hooks/use-gps-diagnostics-feed.ts           # Feed data hook (cursor-paginated)
  lib/hooks/use-employee-gps-gaps.ts              # Calculated gaps hook (drawer)
  lib/hooks/use-employee-gps-events.ts            # Correlated events hook (drawer)
  components/diagnostics/gps-severity-badge.tsx    # Reusable severity + event type badges
  components/diagnostics/gps-kpi-cards.tsx         # 6 KPI cards with delta
  components/diagnostics/gps-trend-chart.tsx       # Recharts grouped bar chart
  components/diagnostics/gps-employee-ranking.tsx  # Sorted employee list
  components/diagnostics/gps-incident-feed.tsx     # Filterable incident table
  components/diagnostics/gps-gaps-list.tsx         # Calculated gaps display (drawer)
  components/diagnostics/gps-correlated-timeline.tsx # Event timeline (drawer)
  components/diagnostics/gps-detail-drawer.tsx     # Right drawer panel
  app/dashboard/diagnostics/page.tsx               # Main page
  components/layout/sidebar.tsx                    # Add nav entry (modify)
```

---

### Task 1: Create Supabase migration with all RPCs

**Files:**
- Create: `supabase/migrations/20260320000000_gps_diagnostics_rpcs.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- GPS Diagnostics Dashboard RPCs
-- Admin-only functions for the GPS diagnostics dashboard
-- ============================================================

-- Helper: classify diagnostic_logs.message into event types
-- Used by all diagnostics RPCs for consistent classification
CREATE OR REPLACE FUNCTION classify_gps_event(p_message TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_message LIKE 'GPS gap detected%' THEN 'gap'
    WHEN p_message LIKE 'Foreground service died%'
      OR p_message LIKE 'Service dead%'
      OR p_message LIKE 'Foreground service start failed%'
      OR p_message LIKE 'Tracking service error%' THEN 'service_died'
    WHEN p_message LIKE 'GPS lost — SLC activated%' THEN 'slc'
    WHEN p_message LIKE 'GPS stream recovered%'
      OR p_message LIKE 'GPS restored%' THEN 'recovery'
    ELSE 'lifecycle'
  END;
$$;

-- ============================================================
-- 1. get_gps_diagnostics_summary
-- Returns KPI aggregates for primary + comparison periods
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_summary(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_compare_start_date TIMESTAMPTZ,
    p_compare_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_primary JSONB;
  v_comparison JSONB;
BEGIN
  -- Aggregate diagnostic_logs counts for a date range
  WITH log_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'gap') AS gaps_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'service_died') AS service_died_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'slc') AS slc_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'recovery') AS recovery_count
    FROM diagnostic_logs
    WHERE event_category = 'gps'
      AND created_at >= p_start_date
      AND created_at < p_end_date
      AND (p_employee_id IS NULL OR employee_id = p_employee_id)
  ),
  -- Calculate GPS gaps from gps_points via shifts in date range
  shift_gaps AS (
    SELECT
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at,
      EXTRACT(EPOCH FROM (gp.captured_at - LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at))) / 60.0 AS gap_min,
      ep.full_name,
      gp.shift_id
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  gap_stats AS (
    SELECT
      COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_min), 0) AS median_gap,
      COALESCE(MAX(gap_min), 0) AS max_gap
    FROM shift_gaps
    WHERE gap_min > 5
  ),
  max_gap_info AS (
    SELECT full_name AS max_gap_employee, captured_at AS max_gap_time
    FROM shift_gaps
    WHERE gap_min > 5
    ORDER BY gap_min DESC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'gaps_count', lc.gaps_count,
    'service_died_count', lc.service_died_count,
    'slc_count', lc.slc_count,
    'recovery_count', lc.recovery_count,
    'recovery_rate', CASE
      WHEN (lc.gaps_count + lc.service_died_count) > 0
      THEN ROUND(lc.recovery_count::NUMERIC / (lc.gaps_count + lc.service_died_count) * 100, 1)
      ELSE 100
    END,
    'median_gap_minutes', ROUND(gs.median_gap::NUMERIC, 1),
    'max_gap_minutes', ROUND(gs.max_gap::NUMERIC, 1),
    'max_gap_employee_name', mgi.max_gap_employee,
    'max_gap_time', mgi.max_gap_time
  ) INTO v_primary
  FROM log_counts lc
  CROSS JOIN gap_stats gs
  LEFT JOIN max_gap_info mgi ON true;

  -- Same for comparison period
  WITH log_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'gap') AS gaps_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'service_died') AS service_died_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'slc') AS slc_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'recovery') AS recovery_count
    FROM diagnostic_logs
    WHERE event_category = 'gps'
      AND created_at >= p_compare_start_date
      AND created_at < p_compare_end_date
      AND (p_employee_id IS NULL OR employee_id = p_employee_id)
  ),
  shift_gaps AS (
    SELECT
      EXTRACT(EPOCH FROM (gp.captured_at - LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at))) / 60.0 AS gap_min
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.clocked_in_at >= p_compare_start_date
      AND s.clocked_in_at < p_compare_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  gap_stats AS (
    SELECT
      COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_min), 0) AS median_gap,
      COALESCE(MAX(gap_min), 0) AS max_gap
    FROM shift_gaps
    WHERE gap_min > 5
  )
  SELECT jsonb_build_object(
    'gaps_count', lc.gaps_count,
    'service_died_count', lc.service_died_count,
    'slc_count', lc.slc_count,
    'recovery_count', lc.recovery_count,
    'recovery_rate', CASE
      WHEN (lc.gaps_count + lc.service_died_count) > 0
      THEN ROUND(lc.recovery_count::NUMERIC / (lc.gaps_count + lc.service_died_count) * 100, 1)
      ELSE 100
    END,
    'median_gap_minutes', ROUND(gs.median_gap::NUMERIC, 1),
    'max_gap_minutes', ROUND(gs.max_gap::NUMERIC, 1)
  ) INTO v_comparison
  FROM log_counts lc
  CROSS JOIN gap_stats gs;

  RETURN jsonb_build_object('primary', v_primary, 'comparison', v_comparison);
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_summary TO authenticated;

-- ============================================================
-- 2. get_gps_diagnostics_trend
-- Returns daily counts for the trend chart
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_trend(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL
)
RETURNS TABLE(
    day DATE,
    gaps_count BIGINT,
    error_count BIGINT,
    recovery_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    (dl.created_at AT TIME ZONE 'America/Montreal')::DATE AS day,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'gap') AS gaps_count,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'service_died') AS error_count,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'recovery') AS recovery_count
  FROM diagnostic_logs dl
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
    AND (p_employee_id IS NULL OR dl.employee_id = p_employee_id)
  GROUP BY 1
  ORDER BY 1;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_trend TO authenticated;

-- ============================================================
-- 3. get_gps_diagnostics_ranking
-- Returns employees ranked by GPS issues
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_ranking(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE(
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    total_gaps BIGINT,
    total_slc BIGINT,
    total_service_died BIGINT,
    total_recoveries BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'gap') AS total_gaps,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'slc') AS total_slc,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'service_died') AS total_service_died,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'recovery') AS total_recoveries
  FROM diagnostic_logs dl
  JOIN employee_profiles ep ON ep.id = dl.employee_id
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
  GROUP BY dl.employee_id, ep.full_name, ep.device_platform, ep.device_model
  HAVING SUM(1) FILTER (WHERE classify_gps_event(dl.message) IN ('gap', 'service_died', 'slc')) > 0
  ORDER BY total_gaps DESC, total_service_died DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_ranking TO authenticated;

-- ============================================================
-- 4. get_gps_diagnostics_feed
-- Returns paginated incident feed with classification
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_feed(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL,
    p_severities TEXT[] DEFAULT ARRAY['warn', 'error', 'critical'],
    p_cursor_time TIMESTAMPTZ DEFAULT NULL,
    p_cursor_id UUID DEFAULT NULL,
    p_limit INT DEFAULT 50
)
RETURNS TABLE(
    id UUID,
    created_at TIMESTAMPTZ,
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    message TEXT,
    event_type TEXT,
    severity TEXT,
    app_version TEXT,
    metadata JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.id,
    dl.created_at,
    dl.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    dl.message,
    classify_gps_event(dl.message) AS event_type,
    dl.severity,
    dl.app_version,
    dl.metadata
  FROM diagnostic_logs dl
  JOIN employee_profiles ep ON ep.id = dl.employee_id
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
    AND dl.severity = ANY(p_severities)
    AND (p_employee_id IS NULL OR dl.employee_id = p_employee_id)
    AND (
      p_cursor_time IS NULL
      OR (dl.created_at, dl.id) < (p_cursor_time, p_cursor_id)
    )
  ORDER BY dl.created_at DESC, dl.id DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_feed TO authenticated;

-- ============================================================
-- 5. get_employee_gps_gaps
-- Calculates real GPS point gaps using LAG() window function
-- ============================================================
CREATE OR REPLACE FUNCTION get_employee_gps_gaps(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_min_gap_minutes NUMERIC DEFAULT 5
)
RETURNS TABLE(
    shift_id UUID,
    gap_start TIMESTAMPTZ,
    gap_end TIMESTAMPTZ,
    gap_minutes NUMERIC,
    shift_clocked_in_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH point_gaps AS (
    SELECT
      gp.shift_id,
      s.clocked_in_at,
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
  )
  SELECT
    pg.shift_id,
    pg.prev_at AS gap_start,
    pg.captured_at AS gap_end,
    ROUND(EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0, 1) AS gap_minutes,
    pg.clocked_in_at AS shift_clocked_in_at
  FROM point_gaps pg
  WHERE pg.prev_at IS NOT NULL
    AND EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0 > p_min_gap_minutes
  ORDER BY gap_minutes DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_employee_gps_gaps TO authenticated;

-- ============================================================
-- 6. get_employee_gps_events
-- Returns all diagnostic events for one employee (all categories)
-- ============================================================
CREATE OR REPLACE FUNCTION get_employee_gps_events(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE(
    id UUID,
    created_at TIMESTAMPTZ,
    event_category TEXT,
    severity TEXT,
    message TEXT,
    metadata JSONB,
    app_version TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.id,
    dl.created_at,
    dl.event_category,
    dl.severity,
    dl.message,
    dl.metadata,
    dl.app_version
  FROM diagnostic_logs dl
  WHERE dl.employee_id = p_employee_id
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
  ORDER BY dl.created_at DESC
  LIMIT 200;
END;
$$;

GRANT EXECUTE ON FUNCTION get_employee_gps_events TO authenticated;
```

- [ ] **Step 2: Apply migration to the live database via MCP**

Use the Supabase MCP `apply_migration` tool with name `20260320000000_gps_diagnostics_rpcs` and the SQL above.

- [ ] **Step 3: Verify RPCs work**

Run via MCP `execute_sql`:
```sql
SELECT * FROM get_gps_diagnostics_trend(
  now() - interval '7 days', now()
);
```
Expected: rows with day, gaps_count, error_count, recovery_count.

```sql
SELECT * FROM get_gps_diagnostics_ranking(
  now() - interval '7 days', now()
);
```
Expected: rows with employee ranking data.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260320000000_gps_diagnostics_rpcs.sql
git commit -m "feat: add GPS diagnostics RPCs (summary, trend, ranking, feed, gaps, events)"
```

---

### Task 2: Install recharts + create TypeScript types

**Files:**
- Modify: `dashboard/package.json`
- Create: `dashboard/src/types/gps-diagnostics.ts`

- [ ] **Step 1: Install recharts**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npm install recharts
```

- [ ] **Step 2: Create types file**

Create `dashboard/src/types/gps-diagnostics.ts`:

```typescript
// =============================================================
// GPS Diagnostics Types
// Types for the /dashboard/diagnostics page
// =============================================================

// ---- Event classification ----

export type GpsEventType = 'gap' | 'service_died' | 'slc' | 'recovery' | 'lifecycle';
export type DiagnosticSeverity = 'info' | 'warn' | 'error' | 'critical';

// ---- Summary (KPI cards) ----

export interface GpsSummaryPeriod {
  gapsCount: number;
  serviceDiedCount: number;
  slcCount: number;
  recoveryCount: number;
  recoveryRate: number;
  medianGapMinutes: number;
  maxGapMinutes: number;
  maxGapEmployeeName: string | null;
  maxGapTime: string | null;
}

export interface GpsSummaryRow {
  primary: {
    gaps_count: number;
    service_died_count: number;
    slc_count: number;
    recovery_count: number;
    recovery_rate: number;
    median_gap_minutes: number;
    max_gap_minutes: number;
    max_gap_employee_name: string | null;
    max_gap_time: string | null;
  };
  comparison: {
    gaps_count: number;
    service_died_count: number;
    slc_count: number;
    recovery_count: number;
    recovery_rate: number;
    median_gap_minutes: number;
    max_gap_minutes: number;
  };
}

export function transformSummary(row: GpsSummaryRow): { primary: GpsSummaryPeriod; comparison: GpsSummaryPeriod } {
  const map = (r: GpsSummaryRow['primary'] | GpsSummaryRow['comparison']): GpsSummaryPeriod => ({
    gapsCount: r.gaps_count,
    serviceDiedCount: r.service_died_count,
    slcCount: r.slc_count,
    recoveryCount: r.recovery_count,
    recoveryRate: r.recovery_rate,
    medianGapMinutes: r.median_gap_minutes,
    maxGapMinutes: r.max_gap_minutes,
    maxGapEmployeeName: 'max_gap_employee_name' in r ? (r as GpsSummaryRow['primary']).max_gap_employee_name : null,
    maxGapTime: 'max_gap_time' in r ? (r as GpsSummaryRow['primary']).max_gap_time : null,
  });
  return { primary: map(row.primary), comparison: map(row.comparison) };
}

// ---- Trend (chart) ----

export interface GpsTrendRow {
  day: string;
  gaps_count: number;
  error_count: number;
  recovery_count: number;
}

export interface GpsTrendPoint {
  day: string;
  gapsCount: number;
  errorCount: number;
  recoveryCount: number;
}

export function transformTrendRow(row: GpsTrendRow): GpsTrendPoint {
  return {
    day: row.day,
    gapsCount: row.gaps_count,
    errorCount: row.error_count,
    recoveryCount: row.recovery_count,
  };
}

// ---- Ranking (employee list) ----

export interface GpsRankingRow {
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  total_gaps: number;
  total_slc: number;
  total_service_died: number;
  total_recoveries: number;
}

export interface GpsRankedEmployee {
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  totalGaps: number;
  totalSlc: number;
  totalServiceDied: number;
  totalRecoveries: number;
}

export function transformRankingRow(row: GpsRankingRow): GpsRankedEmployee {
  return {
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    totalGaps: row.total_gaps,
    totalSlc: row.total_slc,
    totalServiceDied: row.total_service_died,
    totalRecoveries: row.total_recoveries,
  };
}

// ---- Feed (incident table) ----

export interface GpsFeedRow {
  id: string;
  created_at: string;
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  message: string;
  event_type: GpsEventType;
  severity: DiagnosticSeverity;
  app_version: string | null;
  metadata: Record<string, unknown> | null;
}

export interface GpsFeedItem {
  id: string;
  createdAt: Date;
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  message: string;
  eventType: GpsEventType;
  severity: DiagnosticSeverity;
  appVersion: string | null;
  metadata: Record<string, unknown> | null;
}

export function transformFeedRow(row: GpsFeedRow): GpsFeedItem {
  return {
    id: row.id,
    createdAt: new Date(row.created_at),
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    message: row.message,
    eventType: row.event_type,
    severity: row.severity,
    appVersion: row.app_version,
    metadata: row.metadata,
  };
}

// ---- Employee GPS Gaps (drawer) ----

export interface GpsGapRow {
  shift_id: string;
  gap_start: string;
  gap_end: string;
  gap_minutes: number;
  shift_clocked_in_at: string;
}

export interface GpsGap {
  shiftId: string;
  gapStart: Date;
  gapEnd: Date;
  gapMinutes: number;
  shiftClockedInAt: Date;
}

export function transformGapRow(row: GpsGapRow): GpsGap {
  return {
    shiftId: row.shift_id,
    gapStart: new Date(row.gap_start),
    gapEnd: new Date(row.gap_end),
    gapMinutes: row.gap_minutes,
    shiftClockedInAt: new Date(row.shift_clocked_in_at),
  };
}

// ---- Employee Events (drawer timeline) ----

export interface GpsEventRow {
  id: string;
  created_at: string;
  event_category: string;
  severity: DiagnosticSeverity;
  message: string;
  metadata: Record<string, unknown> | null;
  app_version: string | null;
}

export interface GpsEvent {
  id: string;
  createdAt: Date;
  eventCategory: string;
  severity: DiagnosticSeverity;
  message: string;
  metadata: Record<string, unknown> | null;
  appVersion: string | null;
}

export function transformEventRow(row: GpsEventRow): GpsEvent {
  return {
    id: row.id,
    createdAt: new Date(row.created_at),
    eventCategory: row.event_category,
    severity: row.severity,
    message: row.message,
    metadata: row.metadata,
    appVersion: row.app_version,
  };
}

// ---- Drawer state ----

export interface DrawerState {
  isOpen: boolean;
  employeeId: string | null;
  employeeName: string | null;
  devicePlatform: string | null;
  deviceModel: string | null;
}
```

- [ ] **Step 3: Verify types compile**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npx tsc --noEmit src/types/gps-diagnostics.ts
```

- [ ] **Step 4: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/package.json dashboard/package-lock.json dashboard/src/types/gps-diagnostics.ts
git commit -m "feat: add recharts dependency and GPS diagnostics types"
```

---

### Task 3: Create data hooks (6 hooks)

**Files:**
- Create: `dashboard/src/lib/hooks/use-gps-diagnostics-summary.ts`
- Create: `dashboard/src/lib/hooks/use-gps-diagnostics-trend.ts`
- Create: `dashboard/src/lib/hooks/use-gps-diagnostics-ranking.ts`
- Create: `dashboard/src/lib/hooks/use-gps-diagnostics-feed.ts`
- Create: `dashboard/src/lib/hooks/use-employee-gps-gaps.ts`
- Create: `dashboard/src/lib/hooks/use-employee-gps-events.ts`

- [ ] **Step 1: Create summary hook**

Create `dashboard/src/lib/hooks/use-gps-diagnostics-summary.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsSummaryRow, GpsSummaryPeriod } from '@/types/gps-diagnostics';
import { transformSummary } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsSummary(
  startDate: string,
  endDate: string,
  compareStartDate: string,
  compareEndDate: string,
  employeeId?: string | null,
) {
  const { query, result } = useCustom<GpsSummaryRow>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_summary' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_compare_start_date: compareStartDate,
        p_compare_end_date: compareEndDate,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsSummaryRow | undefined;

  const data = useMemo(() => {
    if (!raw?.primary) return null;
    return transformSummary(raw);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
    refetch: query.refetch,
  };
}
```

- [ ] **Step 2: Create trend hook**

Create `dashboard/src/lib/hooks/use-gps-diagnostics-trend.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsTrendRow, GpsTrendPoint } from '@/types/gps-diagnostics';
import { transformTrendRow } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsTrend(
  startDate: string,
  endDate: string,
  employeeId?: string | null,
) {
  const { query, result } = useCustom<GpsTrendRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_trend' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsTrendRow[] | undefined;

  const data: GpsTrendPoint[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformTrendRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
```

- [ ] **Step 3: Create ranking hook**

Create `dashboard/src/lib/hooks/use-gps-diagnostics-ranking.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsRankingRow, GpsRankedEmployee } from '@/types/gps-diagnostics';
import { transformRankingRow } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsRanking(startDate: string, endDate: string) {
  const { query, result } = useCustom<GpsRankingRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_ranking' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsRankingRow[] | undefined;

  const data: GpsRankedEmployee[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformRankingRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
```

- [ ] **Step 4: Create feed hook (with cursor pagination)**

Create `dashboard/src/lib/hooks/use-gps-diagnostics-feed.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo, useState, useCallback, useEffect } from 'react';
import type { GpsFeedRow, GpsFeedItem, DiagnosticSeverity } from '@/types/gps-diagnostics';
import { transformFeedRow } from '@/types/gps-diagnostics';

interface FeedCursor {
  time: string;
  id: string;
}

export function useGpsDiagnosticsFeed(
  startDate: string,
  endDate: string,
  severities: DiagnosticSeverity[],
  employeeId?: string | null,
  autoRefreshEnabled: boolean = true,
) {
  const [accumulatedItems, setAccumulatedItems] = useState<GpsFeedItem[]>([]);
  const [cursor, setCursor] = useState<FeedCursor | null>(null);
  const [hasMore, setHasMore] = useState(true);

  const { query, result } = useCustom<GpsFeedRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_feed' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_severities: severities,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
        ...(cursor ? { p_cursor_time: cursor.time, p_cursor_id: cursor.id } : {}),
        p_limit: 50,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 15_000,
      refetchInterval: !cursor && autoRefreshEnabled ? 30_000 : false,
    },
  });

  const raw = result?.data as GpsFeedRow[] | undefined;

  // Transform raw data (pure computation)
  const currentPage = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformFeedRow);
  }, [raw]);

  // Side effect: update hasMore when data changes
  useEffect(() => {
    if (raw) {
      setHasMore(raw.length === 50);
    }
  }, [raw]);

  // Merge accumulated items with current page for "load more"
  const items = useMemo(() => {
    if (cursor) return [...accumulatedItems, ...currentPage];
    return currentPage;
  }, [cursor, accumulatedItems, currentPage]);

  const loadMore = useCallback(() => {
    if (items.length === 0) return;
    const last = items[items.length - 1];
    setAccumulatedItems(items);
    setCursor({ time: last.createdAt.toISOString(), id: last.id });
  }, [items]);

  const reset = useCallback(() => {
    setAccumulatedItems([]);
    setCursor(null);
    setHasMore(true);
  }, []);

  return {
    items,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
    hasMore,
    loadMore,
    reset,
    refetch: query.refetch,
  };
}
```

- [ ] **Step 5: Create employee GPS gaps hook**

Create `dashboard/src/lib/hooks/use-employee-gps-gaps.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsGapRow, GpsGap } from '@/types/gps-diagnostics';
import { transformGapRow } from '@/types/gps-diagnostics';

export function useEmployeeGpsGaps(
  employeeId: string | null,
  startDate: string,
  endDate: string,
) {
  const { query, result } = useCustom<GpsGapRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_employee_gps_gaps' },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_start_date: startDate,
        p_end_date: endDate,
        p_min_gap_minutes: 5,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!employeeId,
      staleTime: 60_000,
    },
  });

  const raw = result?.data as GpsGapRow[] | undefined;

  const data: GpsGap[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformGapRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
```

- [ ] **Step 6: Create employee events hook**

Create `dashboard/src/lib/hooks/use-employee-gps-events.ts`:

```typescript
'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsEventRow, GpsEvent } from '@/types/gps-diagnostics';
import { transformEventRow } from '@/types/gps-diagnostics';

export function useEmployeeGpsEvents(
  employeeId: string | null,
  startDate: string,
  endDate: string,
) {
  const { query, result } = useCustom<GpsEventRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_employee_gps_events' },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_start_date: startDate,
        p_end_date: endDate,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!employeeId,
      staleTime: 60_000,
    },
  });

  const raw = result?.data as GpsEventRow[] | undefined;

  const data: GpsEvent[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformEventRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
```

- [ ] **Step 7: Verify hooks compile**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npx tsc --noEmit
```

- [ ] **Step 8: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/lib/hooks/use-gps-diagnostics-summary.ts \
  dashboard/src/lib/hooks/use-gps-diagnostics-trend.ts \
  dashboard/src/lib/hooks/use-gps-diagnostics-ranking.ts \
  dashboard/src/lib/hooks/use-gps-diagnostics-feed.ts \
  dashboard/src/lib/hooks/use-employee-gps-gaps.ts \
  dashboard/src/lib/hooks/use-employee-gps-events.ts
git commit -m "feat: add GPS diagnostics data hooks (summary, trend, ranking, feed, gaps, events)"
```

---

### Task 4: Create badge component + KPI cards

**Files:**
- Create: `dashboard/src/components/diagnostics/gps-severity-badge.tsx`
- Create: `dashboard/src/components/diagnostics/gps-kpi-cards.tsx`

- [ ] **Step 1: Create severity badge component**

Create `dashboard/src/components/diagnostics/gps-severity-badge.tsx`:

```typescript
import { Badge } from '@/components/ui/badge';
import type { GpsEventType, DiagnosticSeverity } from '@/types/gps-diagnostics';

const EVENT_TYPE_CONFIG: Record<GpsEventType, { label: string; className: string }> = {
  gap: { label: 'GPS gap', className: 'bg-amber-100 text-amber-800 hover:bg-amber-100' },
  service_died: { label: 'Service died', className: 'bg-red-100 text-red-800 hover:bg-red-100' },
  slc: { label: 'SLC', className: 'bg-purple-100 text-purple-800 hover:bg-purple-100' },
  recovery: { label: 'Recovery', className: 'bg-green-100 text-green-800 hover:bg-green-100' },
  lifecycle: { label: 'Lifecycle', className: 'bg-slate-100 text-slate-600 hover:bg-slate-100' },
};

const SEVERITY_CONFIG: Record<DiagnosticSeverity, { label: string; className: string }> = {
  info: { label: 'info', className: 'bg-blue-100 text-blue-800 hover:bg-blue-100' },
  warn: { label: 'warn', className: 'bg-amber-100 text-amber-800 hover:bg-amber-100' },
  error: { label: 'error', className: 'bg-red-100 text-red-800 hover:bg-red-100' },
  critical: { label: 'critical', className: 'bg-red-200 text-red-900 font-bold hover:bg-red-200' },
};

export function EventTypeBadge({ type }: { type: GpsEventType }) {
  const config = EVENT_TYPE_CONFIG[type];
  return <Badge variant="outline" className={config.className}>{config.label}</Badge>;
}

export function SeverityBadge({ severity }: { severity: DiagnosticSeverity }) {
  const config = SEVERITY_CONFIG[severity];
  return <Badge variant="outline" className={config.className}>{config.label}</Badge>;
}
```

- [ ] **Step 2: Create KPI cards component**

Create `dashboard/src/components/diagnostics/gps-kpi-cards.tsx`:

```typescript
import { Card, CardContent } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { TrendingUp, TrendingDown, Minus } from 'lucide-react';
import type { GpsSummaryPeriod } from '@/types/gps-diagnostics';

interface KpiCardProps {
  label: string;
  value: number | string;
  previousValue?: number;
  unit?: string;
  color: string;
  isLoading?: boolean;
}

function KpiCard({ label, value, previousValue, unit, color, isLoading }: KpiCardProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="py-4">
          <Skeleton className="h-3 w-20 mb-2" />
          <Skeleton className="h-8 w-16" />
          <Skeleton className="h-3 w-14 mt-2" />
        </CardContent>
      </Card>
    );
  }

  const numValue = typeof value === 'number' ? value : parseFloat(value as string);
  const delta = previousValue != null && previousValue > 0
    ? Math.round(((numValue - previousValue) / previousValue) * 100)
    : null;

  return (
    <Card>
      <CardContent className="py-4">
        <p className="text-xs text-slate-500 uppercase tracking-wide">{label}</p>
        <p className={`text-2xl font-bold mt-1 ${color}`}>
          {value}{unit && <span className="text-sm font-normal ml-0.5">{unit}</span>}
        </p>
        {delta !== null && (
          <div className="flex items-center gap-1 mt-1">
            {delta > 0 ? (
              <TrendingUp className="h-3 w-3 text-red-500" />
            ) : delta < 0 ? (
              <TrendingDown className="h-3 w-3 text-green-500" />
            ) : (
              <Minus className="h-3 w-3 text-slate-400" />
            )}
            <span className={`text-xs ${delta > 0 ? 'text-red-500' : delta < 0 ? 'text-green-500' : 'text-slate-400'}`}>
              {delta > 0 ? '+' : ''}{delta}% vs période préc.
            </span>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

interface GpsKpiCardsProps {
  primary: GpsSummaryPeriod | null;
  comparison: GpsSummaryPeriod | null;
  isLoading: boolean;
}

export function GpsKpiCards({ primary, comparison, isLoading }: GpsKpiCardsProps) {
  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
      <KpiCard
        label="Gaps détectés"
        value={primary?.gapsCount ?? 0}
        previousValue={comparison?.gapsCount}
        color="text-amber-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Service died"
        value={primary?.serviceDiedCount ?? 0}
        previousValue={comparison?.serviceDiedCount}
        color="text-red-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="SLC activations"
        value={primary?.slcCount ?? 0}
        previousValue={comparison?.slcCount}
        color="text-purple-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Recovery rate"
        value={primary?.recoveryRate ?? 0}
        previousValue={comparison?.recoveryRate}
        unit="%"
        color="text-green-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Gap moyen"
        value={primary?.medianGapMinutes ?? 0}
        previousValue={comparison?.medianGapMinutes}
        unit="m"
        color="text-blue-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Plus long gap"
        value={primary?.maxGapMinutes ?? 0}
        previousValue={comparison?.maxGapMinutes}
        unit="m"
        color="text-red-600"
        isLoading={isLoading}
      />
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/components/diagnostics/gps-severity-badge.tsx \
  dashboard/src/components/diagnostics/gps-kpi-cards.tsx
git commit -m "feat: add GPS severity badges and KPI cards components"
```

---

### Task 5: Create trend chart + employee ranking

**Files:**
- Create: `dashboard/src/components/diagnostics/gps-trend-chart.tsx`
- Create: `dashboard/src/components/diagnostics/gps-employee-ranking.tsx`

- [ ] **Step 1: Create trend chart**

Create `dashboard/src/components/diagnostics/gps-trend-chart.tsx`:

```typescript
'use client';

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';
import type { GpsTrendPoint } from '@/types/gps-diagnostics';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';

interface GpsTrendChartProps {
  data: GpsTrendPoint[];
  isLoading: boolean;
}

export function GpsTrendChart({ data, isLoading }: GpsTrendChartProps) {
  if (isLoading) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Tendance GPS</CardTitle>
        </CardHeader>
        <CardContent>
          <Skeleton className="h-[250px] w-full" />
        </CardContent>
      </Card>
    );
  }

  if (data.length === 0) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Tendance GPS</CardTitle>
        </CardHeader>
        <CardContent className="flex items-center justify-center h-[250px]">
          <p className="text-sm text-slate-500">Aucune donnée pour cette période</p>
        </CardContent>
      </Card>
    );
  }

  const chartData = data.map((d) => ({
    ...d,
    label: format(parseISO(d.day), 'd MMM', { locale: fr }),
  }));

  return (
    <Card className="h-full">
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">Tendance GPS</CardTitle>
          <div className="flex gap-3 text-xs text-slate-500">
            <span className="flex items-center gap-1">
              <span className="inline-block w-2 h-2 rounded-sm bg-amber-500" /> Gaps
            </span>
            <span className="flex items-center gap-1">
              <span className="inline-block w-2 h-2 rounded-sm bg-red-500" /> Errors
            </span>
            <span className="flex items-center gap-1">
              <span className="inline-block w-2 h-2 rounded-sm bg-green-500" /> Recoveries
            </span>
          </div>
        </div>
      </CardHeader>
      <CardContent>
        <ResponsiveContainer width="100%" height={250}>
          <BarChart data={chartData} barGap={2}>
            <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" />
            <XAxis dataKey="label" tick={{ fontSize: 11 }} stroke="#94a3b8" />
            <YAxis tick={{ fontSize: 11 }} stroke="#94a3b8" />
            <Tooltip
              contentStyle={{ fontSize: 12, borderRadius: 8 }}
              labelFormatter={(label) => `${label}`}
            />
            <Bar dataKey="gapsCount" name="Gaps" fill="#f59e0b" radius={[2, 2, 0, 0]} />
            <Bar dataKey="errorCount" name="Errors" fill="#ef4444" radius={[2, 2, 0, 0]} />
            <Bar dataKey="recoveryCount" name="Recoveries" fill="#22c55e" radius={[2, 2, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 2: Create employee ranking**

Create `dashboard/src/components/diagnostics/gps-employee-ranking.tsx`:

```typescript
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { ChevronRight } from 'lucide-react';
import { cn } from '@/lib/utils';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GpsRankedEmployee } from '@/types/gps-diagnostics';

interface GpsEmployeeRankingProps {
  data: GpsRankedEmployee[];
  isLoading: boolean;
  onSelect: (employee: GpsRankedEmployee) => void;
}

export function GpsEmployeeRanking({ data, isLoading, onSelect }: GpsEmployeeRankingProps) {
  if (isLoading) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          {[...Array(5)].map((_, i) => (
            <Skeleton key={i} className="h-14 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  if (data.length === 0) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
        </CardHeader>
        <CardContent className="flex items-center justify-center py-8">
          <p className="text-sm text-slate-500">Aucun problème GPS détecté pour cette période</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="h-full">
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2">
        {data.slice(0, 10).map((emp, idx) => (
          <button
            key={emp.employeeId}
            onClick={() => onSelect(emp)}
            className={cn(
              'flex w-full items-center rounded-lg p-3 text-left transition-colors',
              'border cursor-pointer hover:shadow-sm',
              idx < 1 ? 'bg-red-50 border-red-200' :
              idx < 3 ? 'bg-amber-50 border-amber-200' :
              'bg-white border-slate-200 hover:bg-slate-50'
            )}
          >
            <div className={cn(
              'w-6 text-sm font-bold',
              idx < 1 ? 'text-red-600' : idx < 3 ? 'text-amber-600' : 'text-slate-500'
            )}>
              {idx + 1}
            </div>
            <div className="flex-1 min-w-0">
              <div className="font-medium text-sm text-slate-900 truncate">{emp.fullName}</div>
              <div className="text-xs text-slate-500">
                {emp.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(emp.deviceModel) ?? ''}
              </div>
            </div>
            <div className="text-right mr-2">
              <div className={cn(
                'font-bold text-sm',
                idx < 1 ? 'text-red-600' : 'text-amber-600'
              )}>
                {emp.totalGaps}
              </div>
              <div className="text-xs text-slate-500">
                gaps{emp.totalSlc > 0 ? ` · ${emp.totalSlc} SLC` : ''}{emp.totalServiceDied > 0 ? ` · ${emp.totalServiceDied} died` : ''}
              </div>
            </div>
            <ChevronRight className="h-4 w-4 text-slate-400" />
          </button>
        ))}
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/components/diagnostics/gps-trend-chart.tsx \
  dashboard/src/components/diagnostics/gps-employee-ranking.tsx
git commit -m "feat: add GPS trend chart and employee ranking components"
```

---

### Task 6: Create incident feed table

**Files:**
- Create: `dashboard/src/components/diagnostics/gps-incident-feed.tsx`

- [ ] **Step 1: Create incident feed component**

Create `dashboard/src/components/diagnostics/gps-incident-feed.tsx`:

```typescript
'use client';

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Loader2 } from 'lucide-react';
import { format } from 'date-fns';
import { EventTypeBadge, SeverityBadge } from './gps-severity-badge';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GpsFeedItem, DiagnosticSeverity } from '@/types/gps-diagnostics';

const SEVERITY_FILTERS: DiagnosticSeverity[] = ['info', 'warn', 'error', 'critical'];

interface GpsIncidentFeedProps {
  items: GpsFeedItem[];
  isLoading: boolean;
  hasMore: boolean;
  onLoadMore: () => void;
  onRowClick: (item: GpsFeedItem) => void;
  activeSeverities: DiagnosticSeverity[];
  onToggleSeverity: (severity: DiagnosticSeverity) => void;
}

export function GpsIncidentFeed({
  items,
  isLoading,
  hasMore,
  onLoadMore,
  onRowClick,
  activeSeverities,
  onToggleSeverity,
}: GpsIncidentFeedProps) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">Feed d&apos;incidents GPS</CardTitle>
          <div className="flex gap-1.5">
            {SEVERITY_FILTERS.map((sev) => (
              <button
                key={sev}
                onClick={() => onToggleSeverity(sev)}
                className={`px-2.5 py-0.5 rounded-full text-xs font-medium transition-colors cursor-pointer ${
                  activeSeverities.includes(sev)
                    ? sev === 'info' ? 'bg-blue-100 text-blue-800'
                    : sev === 'warn' ? 'bg-amber-100 text-amber-800'
                    : 'bg-red-100 text-red-800'
                    : 'bg-slate-100 text-slate-400'
                }`}
              >
                {sev}
              </button>
            ))}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        {isLoading && items.length === 0 ? (
          <div className="p-4 space-y-3">
            {[...Array(5)].map((_, i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="p-8 text-center text-slate-500">
            <p className="font-medium">Aucun événement pour les filtres sélectionnés</p>
            <p className="text-xs mt-1">Essayez d&apos;élargir les filtres de sévérité</p>
          </div>
        ) : (
          <>
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[80px]">Heure</TableHead>
                    <TableHead className="w-[140px]">Employé</TableHead>
                    <TableHead>Événement</TableHead>
                    <TableHead className="w-[100px]">Type</TableHead>
                    <TableHead className="w-[100px]">Appareil</TableHead>
                    <TableHead className="w-[60px]">Ver.</TableHead>
                    <TableHead className="w-[70px]">Sév.</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {items.map((item) => (
                    <TableRow
                      key={item.id}
                      className="cursor-pointer hover:bg-slate-50"
                      onClick={() => onRowClick(item)}
                    >
                      <TableCell className="font-mono text-xs text-slate-500">
                        {format(item.createdAt, 'HH:mm:ss')}
                      </TableCell>
                      <TableCell className="font-medium text-sm">{item.fullName}</TableCell>
                      <TableCell className="text-sm text-slate-600 max-w-[300px] truncate">
                        {item.message}
                      </TableCell>
                      <TableCell><EventTypeBadge type={item.eventType} /></TableCell>
                      <TableCell className="text-xs text-slate-500">
                        {formatDeviceModel(item.deviceModel) ?? ''}
                      </TableCell>
                      <TableCell className="text-xs text-slate-500">
                        {item.appVersion ? `+${item.appVersion.split('+')[1] ?? item.appVersion}` : '—'}
                      </TableCell>
                      <TableCell><SeverityBadge severity={item.severity} /></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            {hasMore && (
              <div className="p-3 text-center border-t">
                <Button variant="ghost" size="sm" onClick={onLoadMore} disabled={isLoading}>
                  {isLoading ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : null}
                  Charger plus
                </Button>
              </div>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/components/diagnostics/gps-incident-feed.tsx
git commit -m "feat: add GPS incident feed table component"
```

---

### Task 7: Create drawer components (gaps list, timeline, drawer shell)

**Files:**
- Create: `dashboard/src/components/diagnostics/gps-gaps-list.tsx`
- Create: `dashboard/src/components/diagnostics/gps-correlated-timeline.tsx`
- Create: `dashboard/src/components/diagnostics/gps-detail-drawer.tsx`

- [ ] **Step 1: Create GPS gaps list**

Create `dashboard/src/components/diagnostics/gps-gaps-list.tsx`:

```typescript
import { cn } from '@/lib/utils';
import { format } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { GpsGap } from '@/types/gps-diagnostics';

interface GpsGapsListProps {
  gaps: GpsGap[];
  isLoading: boolean;
}

export function GpsGapsList({ gaps, isLoading }: GpsGapsListProps) {
  if (isLoading) {
    return <div className="space-y-2">{[...Array(3)].map((_, i) => (
      <div key={i} className="h-14 bg-slate-100 rounded-lg animate-pulse" />
    ))}</div>;
  }

  if (gaps.length === 0) {
    return <p className="text-sm text-slate-500 py-2">Aucun trou GPS détecté</p>;
  }

  return (
    <div className="space-y-2">
      {gaps.map((gap, idx) => (
        <div
          key={`${gap.shiftId}-${idx}`}
          className={cn(
            'rounded-lg border p-3',
            gap.gapMinutes > 30 ? 'bg-red-50 border-red-200' :
            gap.gapMinutes > 15 ? 'bg-amber-50 border-amber-200' :
            'bg-slate-50 border-slate-200'
          )}
        >
          <div className="flex justify-between items-center">
            <span className={cn(
              'font-bold text-sm',
              gap.gapMinutes > 30 ? 'text-red-600' : 'text-amber-600'
            )}>
              {gap.gapMinutes.toFixed(1)} min
            </span>
            <span className="text-xs text-slate-500">
              {format(gap.gapStart, 'd MMM', { locale: fr })}
            </span>
          </div>
          <div className="text-xs text-slate-500 mt-1">
            {format(gap.gapStart, 'HH:mm:ss')} → {format(gap.gapEnd, 'HH:mm:ss')}
          </div>
        </div>
      ))}
    </div>
  );
}
```

- [ ] **Step 2: Create correlated timeline**

Create `dashboard/src/components/diagnostics/gps-correlated-timeline.tsx`:

```typescript
import { cn } from '@/lib/utils';
import { format } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { GpsEvent } from '@/types/gps-diagnostics';

interface GpsCorrelatedTimelineProps {
  events: GpsEvent[];
  isLoading: boolean;
}

const SEVERITY_DOT: Record<string, string> = {
  error: 'bg-red-500',
  critical: 'bg-red-700',
  warn: 'bg-amber-500',
  info: 'bg-blue-400',
};

export function GpsCorrelatedTimeline({ events, isLoading }: GpsCorrelatedTimelineProps) {
  if (isLoading) {
    return <div className="space-y-3">{[...Array(5)].map((_, i) => (
      <div key={i} className="h-12 bg-slate-100 rounded animate-pulse" />
    ))}</div>;
  }

  if (events.length === 0) {
    return <p className="text-sm text-slate-500 py-2">Aucun événement</p>;
  }

  return (
    <div className="border-l-2 border-slate-200 pl-4 space-y-4">
      {events.map((evt) => (
        <div key={evt.id} className="relative">
          <div className={cn(
            'absolute -left-[21px] top-1 w-2.5 h-2.5 rounded-full',
            SEVERITY_DOT[evt.severity] ?? 'bg-slate-300'
          )} />
          <div className="text-xs text-slate-400">
            {format(evt.createdAt, 'd MMM HH:mm:ss', { locale: fr })}
          </div>
          <div className="text-sm text-slate-900">{evt.message}</div>
          <div className="text-xs text-slate-400 mt-0.5">
            {evt.eventCategory} · {evt.severity}
            {evt.metadata && typeof evt.metadata === 'object' && 'battery_level' in evt.metadata
              ? ` · batterie: ${evt.metadata.battery_level}%`
              : ''
            }
          </div>
        </div>
      ))}
    </div>
  );
}
```

- [ ] **Step 3: Create detail drawer**

Create `dashboard/src/components/diagnostics/gps-detail-drawer.tsx`:

```typescript
'use client';

import { X } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { useEmployeeGpsGaps } from '@/lib/hooks/use-employee-gps-gaps';
import { useEmployeeGpsEvents } from '@/lib/hooks/use-employee-gps-events';
import { GpsGapsList } from './gps-gaps-list';
import { GpsCorrelatedTimeline } from './gps-correlated-timeline';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { DrawerState, GpsRankedEmployee } from '@/types/gps-diagnostics';

interface GpsDetailDrawerProps {
  drawer: DrawerState;
  onClose: () => void;
  startDate: string;
  endDate: string;
  rankingData?: GpsRankedEmployee | null;
}

export function GpsDetailDrawer({ drawer, onClose, startDate, endDate, rankingData }: GpsDetailDrawerProps) {
  const { data: gaps, isLoading: gapsLoading } = useEmployeeGpsGaps(
    drawer.employeeId,
    startDate,
    endDate,
  );

  const { data: events, isLoading: eventsLoading } = useEmployeeGpsEvents(
    drawer.employeeId,
    startDate,
    endDate,
  );

  return (
    <div className={cn(
      'fixed inset-y-0 right-0 w-[420px] bg-white border-l-2 border-blue-500 shadow-xl z-50',
      'transform transition-transform duration-200',
      drawer.isOpen ? 'translate-x-0' : 'translate-x-full'
    )}>
      <div className="flex flex-col h-full overflow-y-auto p-5">
        {/* Header */}
        <div className="flex justify-between items-start mb-4">
          <div>
            <h3 className="text-lg font-bold text-slate-900">{drawer.employeeName}</h3>
            <p className="text-xs text-slate-500 mt-0.5">
              {drawer.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(drawer.deviceModel) ?? ''}
            </p>
          </div>
          <Button variant="ghost" size="icon" onClick={onClose} className="h-8 w-8">
            <X className="h-4 w-4" />
          </Button>
        </div>

        {/* Device Info Card */}
        <Card className="mb-4">
          <CardContent className="py-3">
            <div className="grid grid-cols-2 gap-2 text-sm">
              <div><span className="text-slate-500">Plateforme:</span> <strong>{drawer.devicePlatform === 'ios' ? 'iOS' : 'Android'}</strong></div>
              <div><span className="text-slate-500">Appareil:</span> <strong>{formatDeviceModel(drawer.deviceModel) ?? 'N/A'}</strong></div>
              {events.length > 0 && events[0].appVersion && (
                <div><span className="text-slate-500">App:</span> <strong>{events[0].appVersion}</strong></div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Mini KPIs */}
        {rankingData && (
          <div className="grid grid-cols-3 gap-2 mb-4">
            <div className="bg-red-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-red-600">{rankingData.totalServiceDied}</div>
              <div className="text-xs text-red-800">Service died</div>
            </div>
            <div className="bg-amber-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-amber-600">{rankingData.totalGaps}</div>
              <div className="text-xs text-amber-800">GPS gaps</div>
            </div>
            <div className="bg-green-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-green-600">{rankingData.totalRecoveries}</div>
              <div className="text-xs text-green-800">Recoveries</div>
            </div>
          </div>
        )}

        {/* GPS Gaps */}
        <h4 className="text-sm font-semibold text-slate-900 mb-2">Vrais trous GPS calculés</h4>
        <GpsGapsList gaps={gaps} isLoading={gapsLoading} />

        <div className="my-4 border-t" />

        {/* Correlated Events */}
        <h4 className="text-sm font-semibold text-slate-900 mb-2">Événements corrélés</h4>
        <GpsCorrelatedTimeline events={events} isLoading={eventsLoading} />
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/components/diagnostics/gps-gaps-list.tsx \
  dashboard/src/components/diagnostics/gps-correlated-timeline.tsx \
  dashboard/src/components/diagnostics/gps-detail-drawer.tsx
git commit -m "feat: add GPS detail drawer with gaps list and correlated timeline"
```

---

### Task 8: Create main page + sidebar entry

**Files:**
- Create: `dashboard/src/app/dashboard/diagnostics/page.tsx`
- Modify: `dashboard/src/components/layout/sidebar.tsx`

- [ ] **Step 1: Create main page**

Create `dashboard/src/app/dashboard/diagnostics/page.tsx`:

```typescript
'use client';

import { useState, useCallback, useMemo } from 'react';
import { AlertCircle, RefreshCw, Pause, Play } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useGpsDiagnosticsSummary } from '@/lib/hooks/use-gps-diagnostics-summary';
import { useGpsDiagnosticsTrend } from '@/lib/hooks/use-gps-diagnostics-trend';
import { useGpsDiagnosticsRanking } from '@/lib/hooks/use-gps-diagnostics-ranking';
import { useGpsDiagnosticsFeed } from '@/lib/hooks/use-gps-diagnostics-feed';
import { GpsKpiCards } from '@/components/diagnostics/gps-kpi-cards';
import { GpsTrendChart } from '@/components/diagnostics/gps-trend-chart';
import { GpsEmployeeRanking } from '@/components/diagnostics/gps-employee-ranking';
import { GpsIncidentFeed } from '@/components/diagnostics/gps-incident-feed';
import { GpsDetailDrawer } from '@/components/diagnostics/gps-detail-drawer';
import type { DrawerState, DiagnosticSeverity, GpsRankedEmployee, GpsFeedItem } from '@/types/gps-diagnostics';

// Date helpers
function todayStart(): string {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

function todayEnd(): string {
  const d = new Date();
  d.setHours(23, 59, 59, 999);
  return d.toISOString();
}

function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

const DATE_RANGES = [
  { label: "Aujourd'hui", start: () => todayStart(), end: () => todayEnd(), compareStart: () => daysAgo(1), compareEnd: () => todayStart() },
  { label: '7 jours', start: () => daysAgo(7), end: () => todayEnd(), compareStart: () => daysAgo(14), compareEnd: () => daysAgo(7) },
  { label: '14 jours', start: () => daysAgo(14), end: () => todayEnd(), compareStart: () => daysAgo(28), compareEnd: () => daysAgo(14) },
  { label: '30 jours', start: () => daysAgo(30), end: () => todayEnd(), compareStart: () => daysAgo(60), compareEnd: () => daysAgo(30) },
];

export default function DiagnosticsPage() {
  // Filters
  const [dateRangeIdx, setDateRangeIdx] = useState(1); // Default: 7 jours
  const [employeeFilter, setEmployeeFilter] = useState<string | null>(null);
  const [activeSeverities, setActiveSeverities] = useState<DiagnosticSeverity[]>(['warn', 'error', 'critical']);
  const [autoRefresh, setAutoRefresh] = useState(true);

  // Drawer
  const [drawer, setDrawer] = useState<DrawerState>({
    isOpen: false,
    employeeId: null,
    employeeName: null,
    devicePlatform: null,
    deviceModel: null,
  });

  const range = DATE_RANGES[dateRangeIdx];
  const startDate = useMemo(() => range.start(), [dateRangeIdx]);
  const endDate = useMemo(() => range.end(), [dateRangeIdx]);
  const compareStartDate = useMemo(() => range.compareStart(), [dateRangeIdx]);
  const compareEndDate = useMemo(() => range.compareEnd(), [dateRangeIdx]);

  // Data hooks
  const summary = useGpsDiagnosticsSummary(startDate, endDate, compareStartDate, compareEndDate, employeeFilter);
  const trend = useGpsDiagnosticsTrend(startDate, endDate, employeeFilter);
  const ranking = useGpsDiagnosticsRanking(startDate, endDate);
  const feed = useGpsDiagnosticsFeed(startDate, endDate, activeSeverities, employeeFilter, autoRefresh);

  // Handlers
  const openDrawerForEmployee = useCallback((emp: GpsRankedEmployee) => {
    setDrawer({
      isOpen: true,
      employeeId: emp.employeeId,
      employeeName: emp.fullName,
      devicePlatform: emp.devicePlatform,
      deviceModel: emp.deviceModel,
    });
  }, []);

  const openDrawerForFeedItem = useCallback((item: GpsFeedItem) => {
    setDrawer({
      isOpen: true,
      employeeId: item.employeeId,
      employeeName: item.fullName,
      devicePlatform: item.devicePlatform,
      deviceModel: item.deviceModel,
    });
  }, []);

  const closeDrawer = useCallback(() => {
    setDrawer((prev) => ({ ...prev, isOpen: false }));
  }, []);

  const toggleSeverity = useCallback((sev: DiagnosticSeverity) => {
    setActiveSeverities((prev) =>
      prev.includes(sev) ? prev.filter((s) => s !== sev) : [...prev, sev]
    );
  }, []);

  // Find ranking data for drawer employee
  const drawerRankingData = useMemo(() => {
    if (!drawer.employeeId) return null;
    return ranking.data.find((e) => e.employeeId === drawer.employeeId) ?? null;
  }, [drawer.employeeId, ranking.data]);

  const hasError = summary.error || trend.error || ranking.error || feed.error;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold text-slate-900">GPS Diagnostics</h2>
          <div className="flex items-center gap-2 mt-1">
            <p className="text-sm text-slate-500">
              Monitoring des coupures GPS
            </p>
            <button
              onClick={() => setAutoRefresh((v) => !v)}
              className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium cursor-pointer ${
                autoRefresh ? 'bg-green-100 text-green-700' : 'bg-slate-100 text-slate-500'
              }`}
            >
              {autoRefresh ? <Play className="h-3 w-3" /> : <Pause className="h-3 w-3" />}
              {autoRefresh ? 'Live 30s' : 'Paused'}
            </button>
          </div>
        </div>
        <div className="flex gap-2 flex-wrap items-center">
          {DATE_RANGES.map((r, idx) => (
            <button
              key={r.label}
              onClick={() => setDateRangeIdx(idx)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors cursor-pointer ${
                dateRangeIdx === idx
                  ? 'bg-slate-900 text-white'
                  : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
              }`}
            >
              {r.label}
            </button>
          ))}
          <Select
            value={employeeFilter ?? 'all'}
            onValueChange={(val) => setEmployeeFilter(val === 'all' ? null : val)}
          >
            <SelectTrigger className="w-[180px] h-9">
              <SelectValue placeholder="Tous les employés" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Tous les employés</SelectItem>
              {ranking.data.map((emp) => (
                <SelectItem key={emp.employeeId} value={emp.employeeId}>
                  {emp.fullName}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* Error banner */}
      {hasError && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="flex items-center gap-3 py-3">
            <AlertCircle className="h-5 w-5 text-red-600" />
            <div className="text-sm text-red-700 flex-1">
              Erreur lors du chargement des données diagnostiques
            </div>
            <Button variant="outline" size="sm" onClick={() => summary.refetch()}>
              <RefreshCw className="h-3 w-3 mr-1" /> Réessayer
            </Button>
          </CardContent>
        </Card>
      )}

      {/* KPI Cards */}
      <GpsKpiCards
        primary={summary.data?.primary ?? null}
        comparison={summary.data?.comparison ?? null}
        isLoading={summary.isLoading}
      />

      {/* Chart + Ranking grid */}
      <div className="grid gap-6 lg:grid-cols-5">
        <div className="lg:col-span-3">
          <GpsTrendChart data={trend.data} isLoading={trend.isLoading} />
        </div>
        <div className="lg:col-span-2">
          <GpsEmployeeRanking
            data={ranking.data}
            isLoading={ranking.isLoading}
            onSelect={openDrawerForEmployee}
          />
        </div>
      </div>

      {/* Incident Feed */}
      <GpsIncidentFeed
        items={feed.items}
        isLoading={feed.isLoading}
        hasMore={feed.hasMore}
        onLoadMore={feed.loadMore}
        onRowClick={openDrawerForFeedItem}
        activeSeverities={activeSeverities}
        onToggleSeverity={toggleSeverity}
      />

      {/* Detail Drawer */}
      {drawer.employeeId && (
        <GpsDetailDrawer
          drawer={drawer}
          onClose={closeDrawer}
          startDate={startDate}
          endDate={endDate}
          rankingData={drawerRankingData}
        />
      )}

      {/* Drawer overlay */}
      {drawer.isOpen && (
        <div
          className="fixed inset-0 bg-black/20 z-40"
          onClick={closeDrawer}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 2: Add sidebar entry**

In `dashboard/src/components/layout/sidebar.tsx`, add the `Activity` import from lucide-react and add a navigation entry:

```typescript
// Add to imports:
import { Activity } from 'lucide-react';

// Add to navigation array, before the "Rapports" entry:
{
  name: 'Diagnostics GPS',
  href: '/dashboard/diagnostics',
  icon: Activity,
},
```

- [ ] **Step 3: Build check**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npm run build
```

Expected: build passes with no errors. Fix any type errors before committing.

- [ ] **Step 4: Commit**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
git add dashboard/src/app/dashboard/diagnostics/page.tsx \
  dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: add GPS diagnostics page and sidebar navigation entry"
```

---

### Task 9: Verify end-to-end

- [ ] **Step 1: Verify RPCs return data**

Use MCP `execute_sql` to test each RPC:

```sql
-- Summary
SELECT get_gps_diagnostics_summary(
  now() - interval '7 days', now(),
  now() - interval '14 days', now() - interval '7 days'
);

-- Trend
SELECT * FROM get_gps_diagnostics_trend(now() - interval '7 days', now());

-- Ranking
SELECT * FROM get_gps_diagnostics_ranking(now() - interval '7 days', now());

-- Feed (first page)
SELECT * FROM get_gps_diagnostics_feed(now() - interval '1 day', now())
LIMIT 5;
```

- [ ] **Step 2: Run dashboard build**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npm run build
```

Expected: no errors.

- [ ] **Step 3: Run dashboard dev and verify page loads**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npm run dev
```

Navigate to `http://localhost:3000/dashboard/diagnostics` and verify:
- KPI cards render with data
- Chart shows bars
- Employee ranking populates
- Incident feed shows events
- Clicking an employee opens the drawer
- Drawer shows gaps and timeline

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A && git commit -m "fix: address GPS diagnostics page issues found during verification"
```
