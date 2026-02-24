# Quickstart: Reports & Export

**Feature Branch**: `013-reports-export`
**Date**: 2026-01-15
**Estimated Implementation Time**: See tasks.md for breakdown

## Prerequisites

Before implementing this feature, ensure:

1. **Spec 009-012 Complete**: Dashboard foundation, employee management, shift monitoring, and GPS visualization are implemented
2. **Supabase Project Access**: Have access to the Supabase project with admin privileges
3. **Browserless Account**: Sign up at [browserless.io](https://www.browserless.io/) for PDF generation service
4. **Development Environment**: Node.js 18.x, pnpm, Supabase CLI installed

---

## Quick Setup

### 1. Environment Variables

Add to `dashboard/.env.local`:
```bash
# Existing
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key

# New for reports
BROWSERLESS_TOKEN=your-browserless-token
```

Add to `supabase/functions/.env`:
```bash
BROWSERLESS_TOKEN=your-browserless-token
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

### 2. Database Migration

Apply the reports migration:

```bash
cd supabase
supabase migration new reports_export
# Copy content from data-model.md SQL to the migration file
supabase db push
```

### 3. Create Storage Bucket

Via Supabase Dashboard or SQL:

```sql
-- Create the reports bucket (private by default)
INSERT INTO storage.buckets (id, name, public)
VALUES ('reports', 'reports', false);
```

### 4. Deploy Edge Function

```bash
cd supabase
supabase functions new generate-report
# Copy Edge Function code
supabase functions deploy generate-report --no-verify-jwt
supabase secrets set BROWSERLESS_TOKEN=your-token
```

### 5. Enable pg_cron and pg_net

Via Supabase Dashboard:
1. Go to Database > Extensions
2. Enable `pg_cron` (if not already enabled)
3. Enable `pg_net`

---

## Implementation Order

### Phase 1: Core Infrastructure (Priority P1)
1. Database migration (tables, RPC functions, RLS)
2. Edge Function scaffolding
3. Storage bucket setup
4. Basic report generation flow

### Phase 2: Timesheet Report (Priority P1)
1. Report configuration UI
2. Timesheet data RPC function
3. CSV export (client-side)
4. PDF template + generation
5. Download flow

### Phase 3: Additional Reports (Priority P2)
1. Shift History Export
2. Team Activity Summary
3. Attendance Report (P3)

### Phase 4: Report History (Priority P2)
1. History page UI
2. Re-download functionality
3. Report expiration handling

### Phase 5: Scheduling (Priority P4)
1. Schedule management UI
2. pg_cron integration
3. Notification system

---

## Key Implementation Files

### Dashboard (Next.js)

```
dashboard/src/
├── app/dashboard/reports/
│   ├── page.tsx              # Report type selection
│   ├── timesheet/page.tsx    # Timesheet configuration
│   ├── activity/page.tsx     # Activity summary
│   ├── attendance/page.tsx   # Attendance report
│   ├── history/page.tsx      # Report history
│   └── schedules/page.tsx    # Schedule management
├── components/reports/
│   ├── report-config-form.tsx
│   ├── report-preview.tsx
│   ├── report-progress.tsx
│   ├── report-download.tsx
│   ├── report-history-table.tsx
│   └── schedule-form.tsx
├── lib/hooks/
│   ├── use-report-generation.ts
│   └── use-report-history.ts
├── lib/validations/reports.ts
└── types/reports.ts
```

### Supabase

```
supabase/
├── migrations/
│   └── 014_reports_export.sql
└── functions/
    └── generate-report/
        ├── index.ts
        ├── generators/
        │   ├── timesheet.ts
        │   ├── activity-summary.ts
        │   └── attendance.ts
        └── templates/
            ├── base.html
            ├── timesheet.html
            ├── activity-summary.html
            └── attendance.html
```

---

## Testing Checklist

### Unit Tests
- [ ] Zod validation schemas
- [ ] Date range calculations
- [ ] Report config transformations

### Integration Tests
- [ ] RPC function authorization
- [ ] Edge Function PDF generation
- [ ] Storage upload/download
- [ ] Signed URL generation

### E2E Tests (Playwright)
- [ ] Generate timesheet report flow
- [ ] Async report polling
- [ ] Report history download
- [ ] Schedule creation flow

### Manual Testing
- [ ] PDF renders correctly on A4/Letter
- [ ] CSV opens in Excel without issues
- [ ] Large report async processing
- [ ] Report expiration (30 days)

---

## Code Snippets

### Report Generation Hook

```typescript
// dashboard/src/lib/hooks/use-report-generation.ts
import { useCustomMutation } from '@refinedev/core';
import { useState, useCallback } from 'react';

export function useReportGeneration() {
  const [jobId, setJobId] = useState<string | null>(null);
  const [status, setStatus] = useState<'idle' | 'generating' | 'completed' | 'failed'>('idle');

  const { mutateAsync } = useCustomMutation();

  const generate = useCallback(async (config: ReportConfig) => {
    setStatus('generating');

    const result = await mutateAsync({
      url: '',
      method: 'post',
      values: {},
      meta: {
        rpc: 'generate_report',
        rpcParams: {
          p_report_type: config.report_type,
          p_config: config
        }
      }
    });

    setJobId(result.data.job_id);

    if (result.data.status === 'completed') {
      setStatus('completed');
      return result.data.download_url;
    }

    // Poll for async completion
    return pollForCompletion(result.data.job_id);
  }, [mutateAsync]);

  return { generate, jobId, status };
}
```

### Report Config Form

```typescript
// dashboard/src/components/reports/report-config-form.tsx
'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { reportConfigSchema } from '@/lib/validations/reports';
import { DateRangeSelector } from '@/components/dashboard/date-range-selector';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';

export function ReportConfigForm({
  reportType,
  onSubmit,
  isLoading
}: ReportConfigFormProps) {
  const form = useForm({
    resolver: zodResolver(reportConfigSchema),
    defaultValues: {
      date_range: { preset: 'last_month' },
      employee_filter: 'all',
      format: 'pdf'
    }
  });

  return (
    <form onSubmit={form.handleSubmit(onSubmit)}>
      <DateRangeSelector
        value={form.watch('date_range')}
        onChange={(v) => form.setValue('date_range', v)}
      />

      <Select
        value={form.watch('employee_filter')}
        onValueChange={(v) => form.setValue('employee_filter', v)}
      >
        <SelectTrigger>
          <SelectValue placeholder="Select employees" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">All Employees</SelectItem>
          {/* Dynamic team/employee options */}
        </SelectContent>
      </Select>

      <Select
        value={form.watch('format')}
        onValueChange={(v) => form.setValue('format', v)}
      >
        <SelectTrigger>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="pdf">PDF</SelectItem>
          <SelectItem value="csv">CSV</SelectItem>
        </SelectContent>
      </Select>

      <Button type="submit" disabled={isLoading}>
        {isLoading ? 'Generating...' : 'Generate Report'}
      </Button>
    </form>
  );
}
```

### Edge Function PDF Generation

```typescript
// supabase/functions/generate-report/index.ts
import puppeteer from 'puppeteer-core';
import { createClient } from '@supabase/supabase-js';

Deno.serve(async (req) => {
  const { job_id, report_type, config, user_id } = await req.json();

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  try {
    // Update job status to processing
    await supabase
      .from('report_jobs')
      .update({ status: 'processing', started_at: new Date().toISOString() })
      .eq('id', job_id);

    // Fetch report data
    const { data: reportData } = await supabase.rpc(`get_${report_type}_report_data`, {
      p_start_date: config.date_range.start,
      p_end_date: config.date_range.end,
      // ... other params
    });

    // Generate HTML from template
    const html = await renderTemplate(report_type, reportData, config);

    // Generate PDF
    const browser = await puppeteer.connect({
      browserWSEndpoint: `wss://chrome.browserless.io?token=${Deno.env.get('BROWSERLESS_TOKEN')}`
    });

    const page = await browser.newPage();
    await page.setContent(html);
    const pdfBuffer = await page.pdf({ format: 'A4', printBackground: true });
    await browser.close();

    // Upload to storage
    const filename = `${user_id}/${report_type}/${Date.now()}_report.pdf`;
    await supabase.storage
      .from('reports')
      .upload(filename, pdfBuffer, {
        contentType: 'application/pdf'
      });

    // Update job as completed
    await supabase
      .from('report_jobs')
      .update({
        status: 'completed',
        completed_at: new Date().toISOString(),
        file_path: filename,
        file_size_bytes: pdfBuffer.byteLength,
        record_count: reportData.length
      })
      .eq('id', job_id);

    return new Response(JSON.stringify({ success: true, file_path: filename }));

  } catch (error) {
    await supabase
      .from('report_jobs')
      .update({
        status: 'failed',
        error_message: error.message
      })
      .eq('id', job_id);

    return new Response(JSON.stringify({ success: false, error: error.message }), { status: 500 });
  }
});
```

---

## Common Issues

### PDF Generation Fails
- Verify BROWSERLESS_TOKEN is set correctly
- Check Edge Function logs in Supabase Dashboard
- Ensure HTML template is valid

### Storage Upload Fails
- Verify storage bucket exists and is private
- Check service role key has storage access
- Verify file path format is correct

### RPC Authorization Errors
- Ensure user has admin/super_admin role
- Check RLS policies are correctly applied
- Verify auth token is being passed

### Async Polling Not Working
- Check pg_net extension is enabled
- Verify Edge Function is deployed with `--no-verify-jwt`
- Check job status in database directly

---

## Next Steps

After completing this feature:
1. Run full E2E test suite
2. Update sidebar navigation to include Reports link
3. Add reports badge to header for pending notifications
4. Document report types for end users
