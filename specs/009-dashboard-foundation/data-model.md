# Data Model: Dashboard Foundation

**Date**: 2026-01-15 | **Spec**: 009-dashboard-foundation

## Overview

The Dashboard Foundation leverages existing database tables (`employee_profiles`, `shifts`, `gps_points`, `employee_supervisors`) with new server-side aggregation functions. No new tables are required.

## Existing Entities (No Changes)

### employee_profiles
```sql
-- From migration 001, enhanced in 006, 009
CREATE TABLE employee_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id),
  email TEXT UNIQUE NOT NULL,
  full_name TEXT NOT NULL,
  employee_id TEXT,
  status TEXT DEFAULT 'active', -- 'active' | 'inactive' | 'suspended'
  role TEXT DEFAULT 'employee', -- 'employee' | 'manager' | 'admin' | 'super_admin'
  privacy_consent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

### shifts
```sql
-- From migration 001
CREATE TABLE shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID REFERENCES employee_profiles(id),
  status TEXT DEFAULT 'active', -- 'active' | 'completed'
  clocked_in_at TIMESTAMPTZ NOT NULL,
  clock_in_location JSONB, -- {latitude, longitude}
  clocked_out_at TIMESTAMPTZ,
  clock_out_location JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### employee_supervisors
```sql
-- From migration 006
CREATE TABLE employee_supervisors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID REFERENCES employee_profiles(id),
  employee_id UUID REFERENCES employee_profiles(id),
  supervision_type TEXT DEFAULT 'direct', -- 'direct' | 'matrix' | 'temporary'
  effective_from DATE DEFAULT CURRENT_DATE,
  effective_to DATE, -- NULL = currently active
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

## New RPC Response Types

### OrganizationDashboardSummary

Returned by `get_org_dashboard_summary()` RPC function.

```typescript
interface OrganizationDashboardSummary {
  // Employee counts by role
  employee_counts: {
    total: number;
    by_role: {
      employee: number;
      manager: number;
      admin: number;
      super_admin: number;
    };
    active_status: {
      active: number;
      inactive: number;
      suspended: number;
    };
  };

  // Shift statistics
  shift_stats: {
    active_shifts: number;
    completed_today: number;
    total_hours_today: number;
    total_hours_this_week: number;
    total_hours_this_month: number;
  };

  // Data freshness
  generated_at: string; // ISO timestamp
}
```

### ActiveEmployee

Returned in the activity feed from `get_team_active_status()`.

```typescript
interface ActiveEmployee {
  employee_id: string;        // UUID
  display_name: string;       // Full name or email
  email: string;
  employee_number: string | null;
  is_active: boolean;         // Currently clocked in
  current_shift_started_at: string | null;  // ISO timestamp
  today_hours_seconds: number;
  monthly_hours_seconds: number;
  monthly_shift_count: number;
}
```

### TeamSummary

Returned by `get_manager_team_summaries()` for team comparison.

```typescript
interface TeamSummary {
  manager_id: string;         // UUID
  manager_name: string;
  manager_email: string;
  team_size: number;          // Total supervised employees
  active_employees: number;   // Currently clocked in
  total_hours: number;        // In selected period
  total_shifts: number;       // In selected period
  avg_hours_per_employee: number;
}
```

### DateRange

Used for filtering queries.

```typescript
type DateRangePreset = 'today' | 'this_week' | 'this_month' | 'custom';

interface DateRange {
  preset: DateRangePreset;
  start_date?: string;  // ISO date for custom range
  end_date?: string;    // ISO date for custom range
}
```

## New Database Functions

### get_org_dashboard_summary()

Returns aggregated organization-wide statistics. Admin/super_admin only.

```sql
-- Migration: 010_dashboard_aggregations.sql
CREATE OR REPLACE FUNCTION get_org_dashboard_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
  v_caller_role TEXT;
BEGIN
  -- Check caller is admin or super_admin
  SELECT role INTO v_caller_role
  FROM employee_profiles
  WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Access denied: admin or super_admin role required';
  END IF;

  SELECT jsonb_build_object(
    'employee_counts', jsonb_build_object(
      'total', (SELECT COUNT(*) FROM employee_profiles),
      'by_role', (
        SELECT jsonb_object_agg(role, cnt)
        FROM (
          SELECT role, COUNT(*) as cnt
          FROM employee_profiles
          GROUP BY role
        ) r
      ),
      'active_status', (
        SELECT jsonb_object_agg(status, cnt)
        FROM (
          SELECT status, COUNT(*) as cnt
          FROM employee_profiles
          GROUP BY status
        ) s
      )
    ),
    'shift_stats', jsonb_build_object(
      'active_shifts', (SELECT COUNT(*) FROM shifts WHERE status = 'active'),
      'completed_today', (
        SELECT COUNT(*) FROM shifts
        WHERE status = 'completed'
        AND clocked_in_at >= CURRENT_DATE
      ),
      'total_hours_today', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= CURRENT_DATE
      ), 0),
      'total_hours_this_week', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= date_trunc('week', CURRENT_DATE)
      ), 0),
      'total_hours_this_month', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= date_trunc('month', CURRENT_DATE)
      ), 0)
    ),
    'generated_at', NOW()
  ) INTO v_result;

  RETURN v_result;
END;
$$;
```

### get_manager_team_summaries()

Returns all managers with their team aggregates for comparison. Admin/super_admin only.

```sql
CREATE OR REPLACE FUNCTION get_manager_team_summaries(
  p_start_date TIMESTAMPTZ DEFAULT date_trunc('month', CURRENT_DATE),
  p_end_date TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  manager_id UUID,
  manager_name TEXT,
  manager_email TEXT,
  team_size BIGINT,
  active_employees BIGINT,
  total_hours NUMERIC,
  total_shifts BIGINT,
  avg_hours_per_employee NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
BEGIN
  -- Check caller is admin or super_admin
  SELECT role INTO v_caller_role
  FROM employee_profiles
  WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Access denied: admin or super_admin role required';
  END IF;

  RETURN QUERY
  SELECT
    m.id AS manager_id,
    m.full_name AS manager_name,
    m.email AS manager_email,
    COUNT(DISTINCT es.employee_id) AS team_size,
    COUNT(DISTINCT CASE WHEN s.status = 'active' THEN s.employee_id END) AS active_employees,
    COALESCE(SUM(
      EXTRACT(EPOCH FROM (
        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
      )) / 3600
    ), 0)::NUMERIC(10,2) AS total_hours,
    COUNT(s.id) AS total_shifts,
    CASE
      WHEN COUNT(DISTINCT es.employee_id) > 0 THEN
        (COALESCE(SUM(
          EXTRACT(EPOCH FROM (
            COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
          )) / 3600
        ), 0) / COUNT(DISTINCT es.employee_id))::NUMERIC(10,2)
      ELSE 0
    END AS avg_hours_per_employee
  FROM employee_profiles m
  INNER JOIN employee_supervisors es ON es.manager_id = m.id
    AND es.effective_to IS NULL  -- Active supervision only
  LEFT JOIN shifts s ON s.employee_id = es.employee_id
    AND s.clocked_in_at >= p_start_date
    AND s.clocked_in_at < p_end_date
  WHERE m.role IN ('manager', 'admin', 'super_admin')
  GROUP BY m.id, m.full_name, m.email
  ORDER BY total_hours DESC;
END;
$$;
```

## State Transitions

### Dashboard Data Lifecycle

```
[Page Load]
    ↓
[Check Auth] → [Unauthorized] → [Redirect to /login]
    ↓
[Fetch Dashboard Data]
    ↓
[Display with Loading Skeletons]
    ↓
[Data Received] → [Render Stats/Activity/Teams]
    ↓
[30s Timer Expires]
    ↓
[Background Refetch] → [Update UI if data changed]
    ↓
[Manual Refresh Clicked] → [Immediate Refetch]
```

### Data Freshness States

| State | Indicator | Action |
|-------|-----------|--------|
| Fresh (<30s old) | Green dot | None |
| Stale (30s-5min) | Yellow dot | Show "Last updated X ago" |
| Very stale (>5min) | Red dot | Prompt manual refresh |
| Error | Red X | Show error + retry button |

## Validation Rules

### Date Range Validation
- `start_date` must be before `end_date`
- Maximum range: 1 year
- Default: Current month

### Role-Based Access
- Dashboard pages: `admin` or `super_admin` only
- Team drill-down: navigates to existing manager dashboard (from spec 008)

## Indexes for Dashboard Queries

Existing indexes are sufficient for dashboard queries:
- `idx_shifts_status` - Active shift counts
- `idx_shifts_clocked_in_at` - Time-range aggregations
- `idx_employee_supervisors_manager_id` - Team lookups
- `idx_employee_profiles_role` - Role counts
