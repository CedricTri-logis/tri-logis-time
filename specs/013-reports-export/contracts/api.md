# API Contracts: Reports & Export

**Feature Branch**: `013-reports-export`
**Date**: 2026-01-15
**Status**: Complete

## Overview

This document defines the API contracts for the Reports & Export feature. The APIs follow RESTful conventions and use Supabase RPC functions with Refine data hooks.

---

## RPC Functions (Supabase PostgreSQL)

### 1. Generate Report

**Function**: `generate_report`

Initiates report generation, returning job ID for async or direct download URL for sync.

```sql
-- Request
SELECT generate_report(
  p_report_type := 'timesheet',
  p_config := '{
    "date_range": {"start": "2026-01-01", "end": "2026-01-31"},
    "employee_filter": "all",
    "format": "pdf"
  }'::jsonb
);

-- Response (sync - record count <= 1000)
{
  "job_id": "uuid-here",
  "status": "completed",
  "download_url": "https://project.supabase.co/storage/v1/object/sign/reports/...",
  "expires_at": "2026-01-15T12:00:00Z"
}

-- Response (async - record count > 1000)
{
  "job_id": "uuid-here",
  "status": "processing",
  "is_async": true,
  "estimated_duration_seconds": 120
}
```

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| p_report_type | TEXT | Yes | One of: timesheet, activity_summary, attendance, shift_history |
| p_config | JSONB | Yes | Report configuration object |

**Returns**: JSONB with job_id, status, and conditionally download_url

---

### 2. Get Report Job Status

**Function**: `get_report_job_status`

Polls the status of an async report generation job.

```sql
-- Request
SELECT get_report_job_status(p_job_id := 'uuid-here');

-- Response (processing)
{
  "job_id": "uuid-here",
  "status": "processing",
  "started_at": "2026-01-15T10:00:00Z",
  "progress_percent": 45
}

-- Response (completed)
{
  "job_id": "uuid-here",
  "status": "completed",
  "download_url": "https://project.supabase.co/storage/v1/object/sign/reports/...",
  "file_size_bytes": 1048576,
  "record_count": 5000,
  "completed_at": "2026-01-15T10:02:00Z",
  "expires_at": "2026-02-14T10:02:00Z"
}

-- Response (failed)
{
  "job_id": "uuid-here",
  "status": "failed",
  "error_message": "Failed to connect to PDF service",
  "failed_at": "2026-01-15T10:01:30Z"
}
```

---

### 3. Get Report History

**Function**: `get_report_history`

Returns paginated list of generated reports for the current user.

```sql
-- Request
SELECT get_report_history(
  p_limit := 20,
  p_offset := 0,
  p_report_type := NULL  -- Optional filter
);

-- Response
{
  "items": [
    {
      "job_id": "uuid-here",
      "report_type": "timesheet",
      "status": "completed",
      "config": {...},
      "file_path": "user_id/timesheet/...",
      "file_size_bytes": 524288,
      "record_count": 250,
      "created_at": "2026-01-15T10:00:00Z",
      "expires_at": "2026-02-14T10:00:00Z",
      "download_available": true
    }
  ],
  "total_count": 45,
  "has_more": true
}
```

---

### 4. Get Timesheet Report Data

**Function**: `get_timesheet_report_data`

Retrieves timesheet data for preview or export.

```sql
-- Request
SELECT * FROM get_timesheet_report_data(
  p_start_date := '2026-01-01',
  p_end_date := '2026-01-31',
  p_employee_ids := NULL,  -- All authorized employees
  p_include_incomplete := false
);

-- Response (table)
| employee_id | employee_name | employee_identifier | shift_date | clocked_in_at | clocked_out_at | duration_minutes | status | notes |
|-------------|---------------|---------------------|------------|---------------|----------------|------------------|--------|-------|
| uuid-1 | John Doe | EMP001 | 2026-01-15 | 2026-01-15 08:00:00 | 2026-01-15 17:00:00 | 540 | complete | |
```

---

### 5. Get Team Activity Summary

**Function**: `get_team_activity_summary`

Retrieves aggregated team activity metrics.

```sql
-- Request
SELECT * FROM get_team_activity_summary(
  p_start_date := '2026-01-01',
  p_end_date := '2026-01-31',
  p_team_id := NULL  -- Organization-wide
);

-- Response (table)
| period | total_hours | total_shifts | avg_hours_per_employee | employees_active | hours_by_day |
|--------|-------------|--------------|------------------------|------------------|--------------|
| 2026-01 | 4320.50 | 540 | 172.82 | 25 | {"Mon": 880, "Tue": 920, ...} |
```

---

### 6. Get Attendance Report Data

**Function**: `get_attendance_report_data`

Retrieves attendance/absence data for employees.

```sql
-- Request
SELECT * FROM get_attendance_report_data(
  p_start_date := '2026-01-01',
  p_end_date := '2026-01-31',
  p_employee_ids := NULL
);

-- Response (table)
| employee_id | employee_name | total_working_days | days_worked | days_absent | attendance_rate | calendar_data |
|-------------|---------------|--------------------|--------------| ------------|-----------------|---------------|
| uuid-1 | John Doe | 22 | 20 | 2 | 90.91 | {"2026-01-01": true, ...} |
```

---

### 7. Count Report Records

**Function**: `count_report_records`

Counts records to determine sync vs async processing.

```sql
-- Request
SELECT count_report_records(
  p_report_type := 'timesheet',
  p_start_date := '2026-01-01',
  p_end_date := '2026-01-31',
  p_employee_ids := NULL
);

-- Response
{ "count": 1250 }
```

---

### 8. Create Report Schedule

**Function**: `create_report_schedule`

Creates a recurring report schedule.

```sql
-- Request
SELECT create_report_schedule(
  p_name := 'Weekly Payroll Timesheet',
  p_report_type := 'timesheet',
  p_config := '{
    "date_range": {"preset": "last_week"},
    "employee_filter": "all",
    "format": "pdf"
  }'::jsonb,
  p_frequency := 'weekly',
  p_schedule_config := '{
    "day_of_week": 1,
    "time": "08:00",
    "timezone": "America/New_York"
  }'::jsonb
);

-- Response
{
  "schedule_id": "uuid-here",
  "name": "Weekly Payroll Timesheet",
  "next_run_at": "2026-01-20T08:00:00-05:00",
  "status": "active"
}
```

---

### 9. Get Report Schedules

**Function**: `get_report_schedules`

Returns user's report schedules.

```sql
-- Request
SELECT get_report_schedules();

-- Response
{
  "items": [
    {
      "id": "uuid-here",
      "name": "Weekly Payroll Timesheet",
      "report_type": "timesheet",
      "frequency": "weekly",
      "status": "active",
      "next_run_at": "2026-01-20T08:00:00-05:00",
      "last_run_at": "2026-01-13T08:00:00-05:00",
      "last_run_status": "success",
      "run_count": 12
    }
  ],
  "total_count": 3
}
```

---

### 10. Update Report Schedule

**Function**: `update_report_schedule`

Updates an existing schedule.

```sql
-- Request
SELECT update_report_schedule(
  p_schedule_id := 'uuid-here',
  p_name := 'Updated Name',
  p_status := 'paused',
  p_config := NULL,  -- Keep existing
  p_schedule_config := NULL  -- Keep existing
);

-- Response
{
  "id": "uuid-here",
  "status": "paused",
  "updated_at": "2026-01-15T10:00:00Z"
}
```

---

### 11. Delete Report Schedule

**Function**: `delete_report_schedule`

Soft-deletes a schedule (sets status to 'deleted').

```sql
-- Request
SELECT delete_report_schedule(p_schedule_id := 'uuid-here');

-- Response
{ "success": true }
```

---

### 12. Get Pending Notifications

**Function**: `get_pending_report_notifications`

Returns completed reports that user hasn't seen yet.

```sql
-- Request
SELECT get_pending_report_notifications();

-- Response
{
  "count": 2,
  "items": [
    {
      "job_id": "uuid-here",
      "report_type": "timesheet",
      "completed_at": "2026-01-15T08:05:00Z",
      "schedule_name": "Weekly Payroll Timesheet"
    }
  ]
}
```

---

### 13. Mark Notification Seen

**Function**: `mark_report_notification_seen`

Marks a report notification as viewed.

```sql
-- Request
SELECT mark_report_notification_seen(p_job_id := 'uuid-here');

-- Response
{ "success": true }
```

---

## Edge Function: generate-report

**Endpoint**: `POST /functions/v1/generate-report`

Invoked for async report generation. Handles PDF rendering and storage.

### Request

```typescript
interface GenerateReportRequest {
  job_id: string;
  report_type: 'timesheet' | 'activity_summary' | 'attendance' | 'shift_history';
  config: ReportConfig;
  user_id: string;
}
```

### Headers

```
Authorization: Bearer <service_role_key>
Content-Type: application/json
```

### Response

```typescript
interface GenerateReportResponse {
  success: boolean;
  file_path?: string;
  file_size_bytes?: number;
  record_count?: number;
  error?: string;
}
```

### Error Codes

| Code | Description |
|------|-------------|
| 400 | Invalid request parameters |
| 401 | Unauthorized (missing/invalid token) |
| 404 | Job not found |
| 500 | Internal server error (PDF generation failed) |
| 504 | Timeout (report generation exceeded 60s) |

---

## TypeScript Interfaces

### Report Types

```typescript
// Report types enum
type ReportType = 'timesheet' | 'activity_summary' | 'attendance' | 'shift_history';

// Report formats
type ReportFormat = 'pdf' | 'csv';

// Job status
type ReportJobStatus = 'pending' | 'processing' | 'completed' | 'failed';

// Schedule frequency
type ScheduleFrequency = 'weekly' | 'bi_weekly' | 'monthly';

// Schedule status
type ScheduleStatus = 'active' | 'paused' | 'deleted';
```

### ReportConfig

```typescript
interface DateRange {
  preset?: 'this_week' | 'last_week' | 'this_month' | 'last_month';
  start?: string;  // ISO date
  end?: string;    // ISO date
}

interface ReportConfig {
  date_range: DateRange;
  employee_filter: 'all' | string | string[];  // 'team:id', 'employee:id', or array
  format: ReportFormat;
  options?: {
    include_incomplete_shifts?: boolean;
    include_gps_summary?: boolean;
    group_by?: 'employee' | 'date';
  };
}
```

### ReportJob

```typescript
interface ReportJob {
  id: string;
  user_id: string;
  report_type: ReportType;
  status: ReportJobStatus;
  config: ReportConfig;
  started_at?: string;
  completed_at?: string;
  error_message?: string;
  file_path?: string;
  file_size_bytes?: number;
  record_count?: number;
  is_async: boolean;
  schedule_id?: string;
  created_at: string;
  expires_at: string;
}
```

### ReportSchedule

```typescript
interface ScheduleConfig {
  day_of_week?: 0 | 1 | 2 | 3 | 4 | 5 | 6;
  day_of_month?: number;
  time: string;  // "HH:MM"
  week_parity?: 'odd' | 'even';
  timezone: string;
}

interface ReportSchedule {
  id: string;
  user_id: string;
  name: string;
  report_type: ReportType;
  config: ReportConfig;
  frequency: ScheduleFrequency;
  schedule_config: ScheduleConfig;
  status: ScheduleStatus;
  next_run_at: string;
  last_run_at?: string;
  last_run_status?: 'success' | 'failed';
  run_count: number;
  failure_count: number;
  created_at: string;
  updated_at: string;
}
```

---

## Refine Hook Usage

### useGenerateReport

```typescript
import { useCustomMutation } from '@refinedev/core';

const { mutate: generateReport, isLoading } = useCustomMutation<GenerateReportResponse>();

// Usage
generateReport({
  url: '',
  method: 'post',
  values: {
    report_type: 'timesheet',
    config: { ... }
  },
  meta: {
    rpc: 'generate_report',
    rpcParams: {
      p_report_type: 'timesheet',
      p_config: configJson
    }
  }
});
```

### useReportHistory

```typescript
import { useCustom } from '@refinedev/core';

const { data, isLoading } = useCustom<ReportHistoryResponse>({
  url: '',
  method: 'get',
  meta: {
    rpc: 'get_report_history',
    rpcParams: {
      p_limit: 20,
      p_offset: 0,
      p_report_type: null
    }
  }
});
```

### useReportJobStatus (Polling)

```typescript
import { useCustom } from '@refinedev/core';

const { data, refetch } = useCustom<ReportJobStatusResponse>({
  url: '',
  method: 'get',
  meta: {
    rpc: 'get_report_job_status',
    rpcParams: { p_job_id: jobId }
  },
  queryOptions: {
    refetchInterval: isProcessing ? 3000 : false,  // Poll every 3s while processing
    enabled: !!jobId
  }
});
```

---

## Zod Validation Schemas

```typescript
import { z } from 'zod';

export const dateRangeSchema = z.object({
  preset: z.enum(['this_week', 'last_week', 'this_month', 'last_month']).optional(),
  start: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  end: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional()
}).refine(data => data.preset || (data.start && data.end), {
  message: 'Either preset or both start and end dates required'
});

export const reportConfigSchema = z.object({
  date_range: dateRangeSchema,
  employee_filter: z.union([
    z.literal('all'),
    z.string().startsWith('team:'),
    z.string().startsWith('employee:'),
    z.array(z.string().uuid())
  ]),
  format: z.enum(['pdf', 'csv']),
  options: z.object({
    include_incomplete_shifts: z.boolean().optional(),
    include_gps_summary: z.boolean().optional(),
    group_by: z.enum(['employee', 'date']).optional()
  }).optional()
});

export const scheduleConfigSchema = z.object({
  day_of_week: z.number().min(0).max(6).optional(),
  day_of_month: z.number().min(1).max(28).optional(),
  time: z.string().regex(/^([01]\d|2[0-3]):([0-5]\d)$/),
  week_parity: z.enum(['odd', 'even']).optional(),
  timezone: z.string()
}).refine(data => data.day_of_week !== undefined || data.day_of_month !== undefined, {
  message: 'Either day_of_week or day_of_month required'
});

export const createScheduleSchema = z.object({
  name: z.string().min(1).max(100),
  report_type: z.enum(['timesheet', 'activity_summary', 'attendance']),
  config: reportConfigSchema,
  frequency: z.enum(['weekly', 'bi_weekly', 'monthly']),
  schedule_config: scheduleConfigSchema
});
```
