# Data Model: Reports & Export

**Feature Branch**: `013-reports-export`
**Date**: 2026-01-15
**Status**: Complete

## Overview

This document defines the data model for the Reports & Export feature, including new database tables, relationships, and state transitions.

---

## Entity Relationship Diagram

```
┌─────────────────────┐     ┌─────────────────────┐
│  employee_profiles  │     │       shifts        │
│  (existing)         │     │  (existing)         │
└──────────┬──────────┘     └──────────┬──────────┘
           │                           │
           │ generated_by              │ source data
           ▼                           ▼
┌─────────────────────┐     ┌─────────────────────┐
│     report_jobs     │────▶│  report_audit_logs  │
│  (async tracking)   │     │  (compliance)       │
└──────────┬──────────┘     └─────────────────────┘
           │
           │ schedule reference
           ▼
┌─────────────────────┐
│  report_schedules   │
│  (recurring jobs)   │
└─────────────────────┘
```

---

## New Tables

### 1. report_jobs

Tracks report generation requests (both sync and async).

```sql
CREATE TABLE report_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  report_type TEXT NOT NULL CHECK (report_type IN ('timesheet', 'activity_summary', 'attendance', 'shift_history')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),

  -- Report configuration
  config JSONB NOT NULL,
  -- Example config:
  -- {
  --   "date_range": {"start": "2026-01-01", "end": "2026-01-31"},
  --   "employee_filter": "all" | "team:{team_id}" | "employee:{employee_id}",
  --   "format": "pdf" | "csv",
  --   "include_incomplete_shifts": false
  -- }

  -- Execution details
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  error_message TEXT,

  -- Result
  file_path TEXT,              -- Storage path: {user_id}/{report_type}/{timestamp}_{name}.{format}
  file_size_bytes BIGINT,
  record_count INTEGER,        -- Number of records in report

  -- Metadata
  is_async BOOLEAN NOT NULL DEFAULT false,
  schedule_id UUID REFERENCES report_schedules(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '30 days')
);

-- Indexes
CREATE INDEX idx_report_jobs_user_id ON report_jobs(user_id);
CREATE INDEX idx_report_jobs_status ON report_jobs(status) WHERE status IN ('pending', 'processing');
CREATE INDEX idx_report_jobs_created_at ON report_jobs(created_at DESC);
CREATE INDEX idx_report_jobs_expires_at ON report_jobs(expires_at);
```

**Field Descriptions**:
| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key |
| user_id | UUID | User who requested the report |
| report_type | TEXT | Type: timesheet, activity_summary, attendance, shift_history |
| status | TEXT | Current state: pending, processing, completed, failed |
| config | JSONB | Report parameters (date range, filters, format) |
| started_at | TIMESTAMPTZ | When processing began |
| completed_at | TIMESTAMPTZ | When processing finished |
| error_message | TEXT | Error details if failed |
| file_path | TEXT | Supabase Storage path to generated file |
| file_size_bytes | BIGINT | Size of generated file |
| record_count | INTEGER | Number of records included |
| is_async | BOOLEAN | Whether generated asynchronously |
| schedule_id | UUID | Reference to schedule if from recurring job |
| created_at | TIMESTAMPTZ | When request was created |
| expires_at | TIMESTAMPTZ | When file will be deleted (30 days) |

**State Transitions**:
```
pending ─────▶ processing ─────▶ completed
                   │
                   └─────▶ failed
```

---

### 2. report_schedules

Defines recurring report generation schedules.

```sql
CREATE TABLE report_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  name TEXT NOT NULL,
  report_type TEXT NOT NULL CHECK (report_type IN ('timesheet', 'activity_summary', 'attendance')),

  -- Report configuration (same structure as report_jobs.config)
  config JSONB NOT NULL,

  -- Schedule configuration
  frequency TEXT NOT NULL CHECK (frequency IN ('weekly', 'bi_weekly', 'monthly')),
  schedule_config JSONB NOT NULL,
  -- Example schedule_config:
  -- Weekly:    {"day_of_week": 1, "time": "08:00"}  (Monday at 8 AM)
  -- Bi-weekly: {"day_of_week": 5, "time": "17:00", "week_parity": "odd"}
  -- Monthly:   {"day_of_month": 1, "time": "09:00"}

  -- Execution tracking
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'deleted')),
  next_run_at TIMESTAMPTZ NOT NULL,
  last_run_at TIMESTAMPTZ,
  last_run_status TEXT CHECK (last_run_status IN ('success', 'failed')),
  run_count INTEGER NOT NULL DEFAULT 0,
  failure_count INTEGER NOT NULL DEFAULT 0,

  -- Metadata
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_report_schedules_user_id ON report_schedules(user_id);
CREATE INDEX idx_report_schedules_next_run ON report_schedules(next_run_at) WHERE status = 'active';
CREATE INDEX idx_report_schedules_status ON report_schedules(status);
```

**Field Descriptions**:
| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key |
| user_id | UUID | User who created the schedule |
| name | TEXT | User-defined schedule name |
| report_type | TEXT | Type of report to generate |
| config | JSONB | Report parameters (will use relative date ranges) |
| frequency | TEXT | How often: weekly, bi_weekly, monthly |
| schedule_config | JSONB | Day/time configuration |
| status | TEXT | active, paused, or deleted |
| next_run_at | TIMESTAMPTZ | Next scheduled execution time |
| last_run_at | TIMESTAMPTZ | Last execution time |
| last_run_status | TEXT | Success or failure of last run |
| run_count | INTEGER | Total successful runs |
| failure_count | INTEGER | Total failed runs |
| created_at | TIMESTAMPTZ | When schedule was created |
| updated_at | TIMESTAMPTZ | Last modification time |

---

### 3. report_audit_logs

Immutable audit trail for compliance.

```sql
CREATE TABLE report_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID REFERENCES report_jobs(id),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  action TEXT NOT NULL CHECK (action IN ('generated', 'downloaded', 'deleted', 'scheduled')),

  -- Context
  report_type TEXT NOT NULL,
  parameters JSONB NOT NULL,

  -- Result
  status TEXT NOT NULL CHECK (status IN ('success', 'failed')),
  error_message TEXT,
  file_path TEXT,

  -- Metadata
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_report_audit_logs_user_id ON report_audit_logs(user_id);
CREATE INDEX idx_report_audit_logs_created_at ON report_audit_logs(created_at DESC);
CREATE INDEX idx_report_audit_logs_job_id ON report_audit_logs(job_id);
```

**Field Descriptions**:
| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key |
| job_id | UUID | Reference to report_jobs (nullable for old records) |
| user_id | UUID | User who performed the action |
| action | TEXT | generated, downloaded, deleted, scheduled |
| report_type | TEXT | Type of report |
| parameters | JSONB | Full parameter snapshot at time of action |
| status | TEXT | success or failed |
| error_message | TEXT | Error details if failed |
| file_path | TEXT | Storage path (for generated/downloaded) |
| ip_address | INET | Client IP address |
| user_agent | TEXT | Client user agent |
| created_at | TIMESTAMPTZ | When action occurred |

---

## Configuration (JSONB Schemas)

### Report Config Schema

```typescript
interface ReportConfig {
  date_range: {
    preset?: 'this_week' | 'last_week' | 'this_month' | 'last_month';
    start?: string;  // ISO date: "2026-01-01"
    end?: string;    // ISO date: "2026-01-31"
  };
  employee_filter:
    | 'all'
    | `team:${string}`      // team:{supervisor_id}
    | `employee:${string}`  // employee:{employee_id}
    | string[];             // Array of employee IDs
  format: 'pdf' | 'csv';
  options?: {
    include_incomplete_shifts?: boolean;  // Default: false
    include_gps_summary?: boolean;        // Default: false (for shift_history)
    group_by?: 'employee' | 'date';       // For timesheet
  };
}
```

### Schedule Config Schema

```typescript
interface ScheduleConfig {
  // Weekly
  day_of_week?: 0 | 1 | 2 | 3 | 4 | 5 | 6;  // 0 = Sunday
  time: string;  // "HH:MM" in 24h format

  // Bi-weekly (in addition to day_of_week)
  week_parity?: 'odd' | 'even';

  // Monthly (alternative to day_of_week)
  day_of_month?: 1 | 2 | ... | 28;  // Max 28 for all months

  // Timezone
  timezone: string;  // IANA timezone: "America/New_York"
}
```

---

## Row Level Security Policies

### report_jobs

```sql
-- Users can view their own report jobs
CREATE POLICY "Users view own jobs"
ON report_jobs FOR SELECT
USING (user_id = auth.uid());

-- Users can insert their own jobs
CREATE POLICY "Users create own jobs"
ON report_jobs FOR INSERT
WITH CHECK (user_id = auth.uid());

-- Service role can update job status (Edge Functions)
CREATE POLICY "Service role updates jobs"
ON report_jobs FOR UPDATE
USING (auth.jwt()->>'role' = 'service_role');
```

### report_schedules

```sql
-- Users can manage their own schedules
CREATE POLICY "Users manage own schedules"
ON report_schedules FOR ALL
USING (user_id = auth.uid());
```

### report_audit_logs

```sql
-- Users can view their own audit logs
CREATE POLICY "Users view own audit logs"
ON report_audit_logs FOR SELECT
USING (user_id = auth.uid());

-- Insert allowed by service role and authenticated users
CREATE POLICY "Authenticated users create audit logs"
ON report_audit_logs FOR INSERT
WITH CHECK (user_id = auth.uid());
```

---

## RPC Functions

### 1. get_timesheet_report_data

```sql
CREATE OR REPLACE FUNCTION get_timesheet_report_data(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL,
  p_include_incomplete BOOLEAN DEFAULT false
)
RETURNS TABLE (
  employee_id UUID,
  employee_name TEXT,
  employee_identifier TEXT,
  shift_date DATE,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INTEGER,
  status TEXT,
  notes TEXT
) AS $$
-- Implementation with RLS checks
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 2. get_team_activity_summary

```sql
CREATE OR REPLACE FUNCTION get_team_activity_summary(
  p_start_date DATE,
  p_end_date DATE,
  p_team_id UUID DEFAULT NULL
)
RETURNS TABLE (
  period TEXT,
  total_hours DECIMAL(10,2),
  total_shifts INTEGER,
  avg_hours_per_employee DECIMAL(10,2),
  employees_active INTEGER,
  hours_by_day JSONB
) AS $$
-- Implementation with RLS checks
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 3. get_attendance_report_data

```sql
CREATE OR REPLACE FUNCTION get_attendance_report_data(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  employee_name TEXT,
  total_working_days INTEGER,
  days_worked INTEGER,
  days_absent INTEGER,
  attendance_rate DECIMAL(5,2),
  calendar_data JSONB
) AS $$
-- Implementation with RLS checks
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 4. count_report_records

```sql
CREATE OR REPLACE FUNCTION count_report_records(
  p_report_type TEXT,
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS INTEGER AS $$
-- Returns count for sync/async threshold decision
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Cleanup Jobs

### Expired Reports Cleanup

```sql
-- pg_cron job to delete expired reports (runs daily at 2 AM)
SELECT cron.schedule(
  'cleanup-expired-reports',
  '0 2 * * *',
  $$
    -- Delete expired job records and their storage files
    WITH expired AS (
      DELETE FROM report_jobs
      WHERE expires_at < NOW()
      RETURNING file_path
    )
    SELECT delete_storage_files(array_agg(file_path))
    FROM expired;
  $$
);
```

### Audit Log Retention

```sql
-- pg_cron job to archive old audit logs (runs monthly)
SELECT cron.schedule(
  'archive-old-audit-logs',
  '0 3 1 * *',
  $$
    -- Keep audit logs for 1 year, then archive
    -- Implementation depends on archival strategy
  $$
);
```

---

## Storage Structure

```
reports/                          # Supabase Storage bucket
├── {user_id}/                    # User folder
│   ├── timesheet/
│   │   └── 20260115_093000_monthly_jan.pdf
│   ├── activity_summary/
│   │   └── 20260115_100000_team_summary.pdf
│   ├── attendance/
│   │   └── 20260115_110000_attendance.pdf
│   └── shift_history/
│       └── 20260115_120000_john_doe_history.csv
```

---

## Validation Rules

### Date Range
- Start date must be before or equal to end date
- Maximum range: 1 year
- Cannot be in the future

### Employee Filter
- Admin/super_admin: Can filter any employees
- Manager: Can only filter supervised employees
- Invalid employee IDs silently excluded

### Schedule
- Minimum frequency: Weekly
- Time must be valid HH:MM format
- Timezone must be valid IANA timezone

---

## Migration File

Migration file: `supabase/migrations/014_reports_export.sql`

Includes:
1. Create `report_jobs` table
2. Create `report_schedules` table
3. Create `report_audit_logs` table
4. Enable RLS on all tables
5. Create RLS policies
6. Create RPC functions
7. Create cleanup cron jobs
8. Create Supabase Storage bucket via SQL
9. Grant necessary permissions
