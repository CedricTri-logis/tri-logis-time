# Research: Reports & Export

**Feature Branch**: `013-reports-export`
**Date**: 2026-01-15
**Status**: Complete

## Research Summary

This document consolidates research findings for implementing the Reports & Export feature, addressing all technical decisions and best practices.

---

## 1. PDF Generation Strategy

### Decision: Supabase Edge Function with Puppeteer/Browserless

**Rationale**: Server-rendered HTML converted to PDF using Puppeteer via a Browserless service, deployed as a Supabase Edge Function.

**Implementation Details**:
- Use [Browserless](https://www.browserless.io/) as the headless browser service
- Connect to Browserless via WebSocket from Edge Functions
- Render HTML templates to PDF with custom styling
- Edge Functions support this pattern: https://supabase.com/docs/guides/functions/examples/screenshots

**Alternatives Considered**:
1. **Client-side PDF generation (jsPDF, react-pdf)**: Rejected - Limited formatting control, poor handling of complex tables, inconsistent output across browsers
2. **Self-hosted Puppeteer in Docker**: Rejected - Complex infrastructure management, not compatible with Edge Functions
3. **Third-party PDF APIs (PDFShift, DocRaptor)**: Rejected - Additional vendor dependency, cost per document, latency concerns

**Code Pattern**:
```typescript
// supabase/functions/generate-report/index.ts
import puppeteer from 'puppeteer-core';

Deno.serve(async (req) => {
  const browser = await puppeteer.connect({
    browserWSEndpoint: `wss://chrome.browserless.io?token=${Deno.env.get('BROWSERLESS_TOKEN')}`
  });

  const page = await browser.newPage();
  await page.setContent(htmlContent); // HTML template with data
  const pdf = await page.pdf({ format: 'A4' });
  await browser.close();

  return new Response(pdf, {
    headers: { 'Content-Type': 'application/pdf' }
  });
});
```

---

## 2. Report File Storage

### Decision: Supabase Storage with Private Bucket + Signed URLs

**Rationale**: Generated reports stored in a private Supabase Storage bucket with time-limited signed URLs for secure, authorized download.

**Implementation Details**:
- Create private bucket: `reports`
- Store files with path: `{user_id}/{report_type}/{timestamp}_{report_name}.{format}`
- Generate signed URLs valid for 60 minutes (download window)
- 30-day retention policy with automatic cleanup via pg_cron

**Key Patterns from Supabase Docs**:
```typescript
// Upload from Edge Function using service role key
const { data, error } = await supabaseAdmin.storage
  .from('reports')
  .upload(`${userId}/timesheet/${filename}.pdf`, pdfBuffer, {
    contentType: 'application/pdf',
    cacheControl: '3600',
    upsert: false,
  });

// Create signed URL for download (server-side)
const { data, error } = await supabase.storage
  .from('reports')
  .createSignedUrl('path/to/report.pdf', 3600); // 1 hour
```

**Storage Bucket RLS Policy**:
```sql
-- Only allow users to access their own reports
CREATE POLICY "Users access own reports"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'reports' AND
  (storage.foldername(name))[1] = auth.uid()::text
);
```

---

## 3. Async Report Generation

### Decision: Threshold-based async with Edge Function + Database status tracking

**Rationale**: For reports with >1,000 shift records, generate asynchronously. Use database table to track report generation status with polling from client.

**Implementation Details**:
- Threshold: >1,000 shift records triggers async mode
- Status tracking table: `report_jobs` with states: `pending`, `processing`, `completed`, `failed`
- Client polls for status every 3 seconds until completion
- Notification via dashboard badge when complete (no email)

**Sync vs Async Decision Flow**:
```
1. Client requests report generation
2. Server counts shift records for date range
3. If count <= 1000:
   - Generate report synchronously
   - Return download URL immediately
4. If count > 1000:
   - Create report_job record (status: pending)
   - Return job_id to client
   - Invoke Edge Function asynchronously
   - Client polls for completion
   - On completion: update job status, store file, client downloads
```

---

## 4. Report Scheduling

### Decision: pg_cron for recurring schedules with pg_net for Edge Function invocation

**Rationale**: Use Supabase's built-in pg_cron extension for scheduling with pg_net to invoke Edge Functions for report generation.

**Implementation Details**:
- Store schedule configuration in `report_schedules` table
- pg_cron job runs every 5 minutes to check for due schedules
- Uses pg_net to invoke Edge Function for report generation
- In-app notification on completion (dashboard badge)

**pg_cron + pg_net Pattern**:
```sql
-- Master scheduler job (runs every 5 minutes)
SELECT cron.schedule(
  'process-report-schedules',
  '*/5 * * * *',
  $$
    SELECT process_due_report_schedules();
  $$
);

-- Function to process due schedules
CREATE OR REPLACE FUNCTION process_due_report_schedules()
RETURNS void AS $$
DECLARE
  schedule_record RECORD;
BEGIN
  FOR schedule_record IN
    SELECT * FROM report_schedules
    WHERE status = 'active'
    AND next_run_at <= NOW()
  LOOP
    -- Invoke Edge Function via pg_net
    PERFORM net.http_post(
      url := 'https://project-ref.supabase.co/functions/v1/generate-report',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || current_setting('app.service_role_key'),
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'schedule_id', schedule_record.id,
        'report_config', schedule_record.config
      )
    );

    -- Update next run time
    UPDATE report_schedules
    SET next_run_at = calculate_next_run(schedule_record.frequency),
        last_run_at = NOW()
    WHERE id = schedule_record.id;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Frequency Options**:
- Weekly: Runs on specified day at specified time
- Bi-weekly: Runs every other week on specified day
- Monthly: Runs on specified day of month

---

## 5. Audit Logging

### Decision: Dedicated `report_audit_logs` table with SECURITY DEFINER functions

**Rationale**: Log all report generation events for compliance. Use database triggers and explicit logging in Edge Functions.

**Log Entry Fields**:
- `id`: UUID primary key
- `user_id`: Who generated the report
- `report_type`: Type of report (timesheet, activity, attendance)
- `parameters`: JSON of report parameters (date range, filters)
- `status`: Generation status (started, completed, failed)
- `file_path`: Storage path of generated file
- `created_at`: Timestamp

---

## 6. CSV Export Best Practices

### Decision: Client-side generation for small datasets, server-side for bulk

**Rationale**: Leverage existing GPS export patterns in the codebase. For bulk exports (>100 employees), generate server-side and store in Supabase Storage.

**Existing Pattern** (from `dashboard/src/lib/utils/export-gps.ts`):
- Chunked processing (1000 rows/batch)
- Progress callbacks for UI feedback
- Metadata header with report context
- Blob download with proper MIME types

**CSV Format Standards**:
- UTF-8 encoding with BOM for Excel compatibility
- ISO 8601 date formats
- Properly escaped special characters
- Header row with clear column names

---

## 7. Report Data Aggregation

### Decision: Postgres RPC functions for efficient data aggregation

**Rationale**: Leverage existing RPC pattern with SECURITY DEFINER for proper access control. Create specialized functions for each report type.

**Required New RPC Functions**:

1. **get_timesheet_report_data**: Aggregates shift data for timesheet reports
2. **get_team_activity_summary**: Computes team-level metrics
3. **get_attendance_report_data**: Calculates attendance/absence records
4. **count_shift_records_for_report**: Determines sync vs async threshold

**Authorization Pattern** (from existing migrations):
```sql
-- Check caller's role and filter accordingly
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin') THEN
    -- Filter to supervised employees only
    ...
  END IF;
END;
```

---

## 8. HTML Report Templates

### Decision: Server-side HTML templates with Tailwind CSS

**Rationale**: Use HTML/CSS for PDF generation via Puppeteer. Include Tailwind CSS utility classes inline for consistent styling.

**Template Structure**:
```
templates/
├── base.html           # Layout with header/footer/page numbers
├── timesheet.html      # Timesheet-specific layout
├── activity-summary.html
└── attendance.html
```

**PDF Layout Requirements**:
- A4/Letter paper size support
- Professional header with company/report info
- Page numbers in footer
- Table-based data presentation
- Print-optimized CSS

---

## 9. Error Handling & Retry Logic

### Decision: Graceful degradation with retry for transient failures

**Implementation Details**:
- Edge Function timeout: 60 seconds
- Retry attempts: 3 for transient failures (network, Browserless)
- Failed jobs: Update status to 'failed' with error message
- User notification: Display error in report history with retry option

---

## 10. Performance Optimization

### Decision: Pagination, caching, and progressive loading

**Strategies**:
1. **Report History**: Paginate with 20 items per page
2. **Data Queries**: Use cursor-based pagination for large datasets
3. **Preview Mode**: Show first 10 rows before generating full report
4. **Client Cache**: 5-minute cache for report history list

**Performance Targets** (from Success Criteria):
- SC-001: 100 employees monthly report in 30 seconds
- SC-007: 10,000 shift records in 2 minutes

---

## Technology Dependencies

| Dependency | Purpose | Version |
|------------|---------|---------|
| Browserless | Headless Chrome for PDF | Latest |
| pg_cron | Scheduled jobs | 1.6.4+ |
| pg_net | HTTP requests from Postgres | 0.12.0+ |
| @tanstack/react-table | Report preview tables | Latest |
| date-fns | Date formatting | 4.1.0 |
| zod | Validation schemas | 3.x |

---

## Open Questions (Resolved)

| Question | Resolution |
|----------|------------|
| PDF generation method? | Browserless via Edge Function |
| Storage for reports? | Supabase Storage private bucket |
| Async notification? | In-app only (dashboard badge) |
| Async threshold? | >1,000 shift records |
| Schedule execution? | pg_cron + pg_net |
| Audit logging? | Dedicated table with SECURITY DEFINER |

---

## References

- Supabase Puppeteer Example: https://supabase.com/docs/guides/functions/examples/screenshots
- Supabase Storage Signed URLs: https://supabase.com/docs/guides/storage/serving/downloads
- Supabase pg_cron: https://supabase.com/docs/guides/cron
- Supabase pg_net: https://supabase.com/docs/guides/database/extensions/pg_net
- Existing GPS Export: `dashboard/src/lib/utils/export-gps.ts`
- Existing RPC Patterns: `supabase/migrations/013_gps_visualization.sql`
