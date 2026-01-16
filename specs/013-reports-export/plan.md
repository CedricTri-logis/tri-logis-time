# Implementation Plan: Reports & Export

**Branch**: `013-reports-export` | **Date**: 2026-01-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/013-reports-export/spec.md`

## Summary

Implement a comprehensive reporting and export system for the GPS Tracker manager dashboard. The system enables administrators and supervisors to generate Timesheet Reports (P1), Shift History Exports (P2), Team Activity Summaries (P2), Attendance Reports (P3), and Schedule automated reports (P4). Reports are generated via Supabase Edge Functions with PDF rendering using Puppeteer, stored in Supabase Storage with signed URLs, and support CSV/PDF export formats. Async processing triggers for datasets exceeding 1,000 shift records.

## Technical Context

**Language/Version**: TypeScript 5.x / Node.js 18.x LTS
**Primary Dependencies**: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, @tanstack/react-table, date-fns 4.1.0
**Storage**: PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points, employee_supervisors), Supabase Storage (new: reports bucket)
**Testing**: Playwright for E2E, Jest/Vitest for unit tests
**Target Platform**: Web (Chrome, Safari, Firefox latest 2 versions), Desktop-first
**Project Type**: Web application (dashboard extension)
**Performance Goals**: Generate monthly report for 100 employees within 30 seconds (SC-001), 10,000 shift records within 2 minutes (SC-007)
**Constraints**: Async processing for >1,000 shift records, 30-day report retention, 90-day GPS data retention
**Scale/Scope**: Organization-wide reporting, multi-employee bulk exports, scheduled recurring reports

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | Uses Next.js 14+, shadcn/ui, Refine, Tailwind, Zod |
| IV. Privacy & Compliance | ✅ PASS | RLS enforced (FR-014), audit logging (FR-014a), supervisor-scoped data |
| VI. Simplicity & Maintainability | ✅ PASS | Extends existing dashboard patterns, uses established RPC conventions |

**Platform Requirements Check:**
- Web/Desktop: ✅ Next.js App Router, Refine hooks, shadcn/ui components
- Backend/Supabase: ✅ RLS enforced, manager role access, audit logging

## Project Structure

### Documentation (this feature)

```text
specs/013-reports-export/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
dashboard/
├── src/
│   ├── app/dashboard/reports/
│   │   ├── page.tsx                 # Reports landing (report type selection)
│   │   ├── timesheet/page.tsx       # Timesheet report configuration
│   │   ├── activity/page.tsx        # Team activity summary
│   │   ├── attendance/page.tsx      # Attendance report
│   │   ├── history/page.tsx         # Report history & downloads
│   │   └── schedules/page.tsx       # Scheduled reports management
│   ├── components/
│   │   └── reports/
│   │       ├── report-config-form.tsx    # Date range, filters, format selection
│   │       ├── report-preview.tsx        # Preview before generation
│   │       ├── report-progress.tsx       # Async generation progress
│   │       ├── report-download.tsx       # Download completed reports
│   │       ├── report-history-table.tsx  # History list with re-download
│   │       └── schedule-form.tsx         # Schedule configuration
│   ├── lib/
│   │   ├── hooks/
│   │   │   ├── use-report-generation.ts  # Report generation hook
│   │   │   └── use-report-history.ts     # Report history hook
│   │   ├── utils/
│   │   │   └── report-export.ts          # CSV export utilities (client-side)
│   │   └── validations/
│   │       └── reports.ts                # Zod schemas for report configs
│   └── types/
│       └── reports.ts                    # Report-related TypeScript interfaces

supabase/
├── migrations/
│   └── 014_reports_export.sql            # New tables, RPC functions
└── functions/
    └── generate-report/
        ├── index.ts                      # Edge function entry
        ├── generators/
        │   ├── timesheet.ts              # Timesheet report generator
        │   ├── activity-summary.ts       # Activity summary generator
        │   └── attendance.ts             # Attendance report generator
        └── templates/
            ├── base.html                 # Base PDF template
            ├── timesheet.html            # Timesheet HTML template
            ├── activity-summary.html     # Activity summary template
            └── attendance.html           # Attendance report template
```

**Structure Decision**: Extends existing dashboard structure under `app/dashboard/reports/` following established patterns. New Supabase Edge Function for PDF generation. Report storage in dedicated Supabase Storage bucket.

## Complexity Tracking

> No constitution violations requiring justification. Feature follows established patterns.

---

## Post-Design Constitution Check

*Re-evaluation after Phase 1 design completion.*

| Principle | Status | Post-Design Notes |
|-----------|--------|-------------------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | Confirmed: Next.js 14+ App Router, shadcn/ui components, Refine hooks (useCustom, useCustomMutation), Tailwind CSS, Zod validation schemas |
| IV. Privacy & Compliance | ✅ PASS | Confirmed: RLS on all new tables, SECURITY DEFINER RPC functions check user roles, audit logging for all report generation, supervisor-scoped data access |
| VI. Simplicity & Maintainability | ✅ PASS | Confirmed: Follows existing RPC patterns from migrations 010-013, reuses date-range-selector component, extends export utilities from GPS export |

**Backend Requirements Verification:**
- ✅ RLS enabled on report_jobs, report_schedules, report_audit_logs tables
- ✅ Manager role access enforced in all RPC functions
- ✅ Supabase Storage bucket with private access model
- ✅ Signed URLs for secure, time-limited downloads

**New External Dependency:**
- Browserless.io (PDF generation service) - Justified: Puppeteer in Edge Functions requires external headless browser service. No viable client-side alternative for complex PDF generation.

**Conclusion**: Design phase complete. All constitutional requirements satisfied. Ready for task generation via `/speckit.tasks`.
