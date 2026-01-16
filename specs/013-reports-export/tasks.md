# Tasks: Reports & Export

**Input**: Design documents from `/specs/013-reports-export/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/api.md, quickstart.md

**Tests**: Not explicitly requested in specification - test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4, US5)
- Include exact file paths in descriptions

## Path Conventions

- **Dashboard (Next.js)**: `dashboard/src/`
- **Supabase**: `supabase/migrations/`, `supabase/functions/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, shared types, and basic structure

- [X] T001 [P] Create TypeScript report types and interfaces in dashboard/src/types/reports.ts
- [X] T002 [P] Create Zod validation schemas for report configuration in dashboard/src/lib/validations/reports.ts
- [X] T003 [P] Create reports page layout with navigation in dashboard/src/app/dashboard/reports/layout.tsx
- [X] T004 Create reports landing page (report type selection cards) in dashboard/src/app/dashboard/reports/page.tsx

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Database schema, Edge Function scaffold, storage bucket - MUST complete before ANY user story

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Create database migration with report_jobs, report_schedules, report_audit_logs tables and RLS policies in supabase/migrations/014_reports_export.sql
- [X] T006 Create RPC functions (generate_report, get_report_job_status, count_report_records, get_report_history) in supabase/migrations/014_reports_export.sql
- [X] T007 Create Supabase Storage bucket 'reports' with private access and storage policies in supabase/migrations/014_reports_export.sql
- [X] T008 [P] Create Edge Function scaffold with Browserless connection in supabase/functions/generate-report/index.ts
- [X] T009 [P] Create base HTML template for PDF reports in supabase/functions/generate-report/templates/base.html
- [X] T010 [P] Create useReportGeneration hook (sync/async handling, polling) in dashboard/src/lib/hooks/use-report-generation.ts
- [X] T011 [P] Create useReportHistory hook in dashboard/src/lib/hooks/use-report-history.ts
- [X] T012 [P] Create report configuration form component (date range, employee filter, format) in dashboard/src/components/reports/report-config-form.tsx
- [X] T013 [P] Create report progress component (async polling UI) in dashboard/src/components/reports/report-progress.tsx
- [X] T014 [P] Create report download component (signed URL handling) in dashboard/src/components/reports/report-download.tsx
- [X] T015 Add Reports link to dashboard sidebar navigation in dashboard/src/components/layout/sidebar.tsx

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Generate Organization Timesheet Report (Priority: P1) MVP

**Goal**: Administrators can generate comprehensive timesheet reports for pay period processing

**Independent Test**: Log in as admin, select date range and employee group, generate timesheet report, verify report contains accurate shift data with total hours matching individual shift records

### Implementation for User Story 1

- [X] T016 [US1] Create get_timesheet_report_data RPC function with role-based filtering in supabase/migrations/014_reports_export.sql
- [X] T017 [P] [US1] Create timesheet HTML template with employee shifts table, totals, incomplete shift warnings in supabase/functions/generate-report/templates/timesheet.html
- [X] T018 [US1] Create timesheet generator module in supabase/functions/generate-report/generators/timesheet.ts
- [X] T019 [US1] Create timesheet report configuration page in dashboard/src/app/dashboard/reports/timesheet/page.tsx
- [X] T020 [P] [US1] Create client-side CSV export utility for timesheet data in dashboard/src/lib/utils/report-export.ts
- [X] T021 [US1] Implement timesheet report flow: config form, preview, generate, download in dashboard/src/app/dashboard/reports/timesheet/page.tsx
- [X] T022 [US1] Add timesheet report type handling to Edge Function in supabase/functions/generate-report/index.ts
- [X] T023 [US1] Create report preview component (first 10 rows) in dashboard/src/components/reports/report-preview.tsx

**Checkpoint**: Timesheet Report (US1) is fully functional - admin can generate and download PDF/CSV reports

---

## Phase 4: User Story 2 - Export Employee Shift History (Priority: P2)

**Goal**: Supervisors/admins can export detailed shift history for individual or multiple employees

**Independent Test**: Select an employee, specify date range, export shift history, verify export contains all shifts with complete details

### Implementation for User Story 2

- [X] T024 [US2] Create get_shift_history_export_data RPC function with supervisor scoping in supabase/migrations/014_reports_export.sql
- [X] T025 [P] [US2] Create shift history HTML template with employee details, shift table, summary stats in supabase/functions/generate-report/templates/shift-history.html
- [X] T026 [US2] Create shift history generator module in supabase/functions/generate-report/generators/shift-history.ts
- [X] T027 [US2] Add shift_history report type handling to Edge Function in supabase/functions/generate-report/index.ts
- [X] T028 [US2] Create employee selector component for bulk export (multi-select) in dashboard/src/components/reports/employee-selector.tsx
- [X] T029 [US2] Create shift history export page in dashboard/src/app/dashboard/reports/exports/page.tsx (Note: this is shift history export, not report history)

**Checkpoint**: Shift History Export (US2) is fully functional - can export single or bulk employee histories

---

## Phase 5: User Story 3 - Generate Team Activity Summary Report (Priority: P2)

**Goal**: Managers/admins can generate aggregate team metrics for planning and reporting

**Independent Test**: Select team and date range, generate summary report, verify aggregate metrics match sum of individual data

### Implementation for User Story 3

- [X] T030 [US3] Create get_team_activity_summary RPC function with team breakdown in supabase/migrations/014_reports_export.sql
- [X] T031 [P] [US3] Create activity summary HTML template with metrics, charts placeholders, day-of-week breakdown in supabase/functions/generate-report/templates/activity-summary.html
- [X] T032 [US3] Create activity summary generator module in supabase/functions/generate-report/generators/activity-summary.ts
- [X] T033 [US3] Add activity_summary report type handling to Edge Function in supabase/functions/generate-report/index.ts
- [X] T034 [US3] Create team activity summary page in dashboard/src/app/dashboard/reports/activity/page.tsx

**Checkpoint**: Team Activity Summary (US3) is fully functional - can generate team/org-wide metrics

---

## Phase 6: User Story 4 - Generate Attendance Report (Priority: P3)

**Goal**: Administrators can generate attendance reports showing presence, absences, and patterns

**Independent Test**: Generate attendance report for a period, verify it shows working days, days with/without shifts, attendance patterns

### Implementation for User Story 4

- [X] T035 [US4] Create get_attendance_report_data RPC function with calendar data generation in supabase/migrations/014_reports_export.sql
- [X] T036 [P] [US4] Create attendance HTML template with calendar view, attendance rates, summary in supabase/functions/generate-report/templates/attendance.html
- [X] T037 [US4] Create attendance generator module in supabase/functions/generate-report/generators/attendance.ts
- [X] T038 [US4] Add attendance report type handling to Edge Function in supabase/functions/generate-report/index.ts
- [X] T039 [US4] Create attendance report page in dashboard/src/app/dashboard/reports/attendance/page.tsx

**Checkpoint**: Attendance Report (US4) is fully functional - can generate attendance/absence records

---

## Phase 7: User Story 5 - Schedule and Automate Reports (Priority: P4)

**Goal**: Administrators can schedule recurring reports for automatic generation

**Independent Test**: Schedule a weekly timesheet report, wait for scheduled time, verify report is generated and available

### Implementation for User Story 5

- [X] T040 [US5] Create schedule-related RPC functions (create_report_schedule, get_report_schedules, update_report_schedule, delete_report_schedule) in supabase/migrations/014_reports_export.sql
- [X] T041 [US5] Create pg_cron job for processing due schedules with pg_net Edge Function invocation in supabase/migrations/014_reports_export.sql
- [X] T042 [P] [US5] Create schedule form component (frequency, day/time, timezone selection) in dashboard/src/components/reports/schedule-form.tsx
- [X] T043 [P] [US5] Create useReportSchedules hook in dashboard/src/lib/hooks/use-report-schedules.ts
- [X] T044 [US5] Create scheduled reports management page (list, edit, delete, pause) in dashboard/src/app/dashboard/reports/schedules/page.tsx
- [X] T045 [US5] Create notification-related RPC functions (get_pending_report_notifications, mark_report_notification_seen) in supabase/migrations/014_reports_export.sql
- [X] T046 [US5] Add notification badge component to dashboard header in dashboard/src/components/layout/header.tsx

**Checkpoint**: Report Scheduling (US5) is fully functional - can create/manage recurring report schedules

---

## Phase 8: Report History & Cross-Cutting Concerns

**Purpose**: Report history page, audit logging, cleanup, and polish

- [X] T047 [P] Create report history table component with re-download, expiration display in dashboard/src/components/reports/report-history-table.tsx
- [X] T048 Create report history page in dashboard/src/app/dashboard/reports/history/page.tsx (rename existing to exports/)
- [X] T049 [P] Add audit logging triggers for report generation events in supabase/migrations/014_reports_export.sql
- [X] T050 [P] Create pg_cron job for expired reports cleanup (30-day retention) in supabase/migrations/014_reports_export.sql
- [X] T051 Add error handling and retry logic to Edge Function in supabase/functions/generate-report/index.ts
- [X] T052 Validate all report types render correctly in PDF format (A4/Letter)
- [X] T053 Validate CSV exports open correctly in Excel/Google Sheets
- [X] T054 Run quickstart.md manual validation checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Foundational phase completion
  - User stories can proceed in priority order (P1 -> P2 -> P2 -> P3 -> P4)
  - Or in parallel if team capacity allows
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1 - Timesheet)**: Can start after Foundational - MVP target
- **User Story 2 (P2 - Shift History)**: Can start after Foundational - Uses shared components from US1
- **User Story 3 (P2 - Activity Summary)**: Can start after Foundational - Independent from US1/US2
- **User Story 4 (P3 - Attendance)**: Can start after Foundational - Independent
- **User Story 5 (P4 - Scheduling)**: Can start after Foundational - Uses report generation from US1-4

### Within Each User Story

- RPC functions before Edge Function handlers
- Edge Function handlers before UI pages
- Templates can run in parallel with other story tasks
- Story complete before moving to next priority (recommended)

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel (T008-T014)
- Templates (T017, T025, T031, T036) can be created in parallel
- Hooks (T010, T011, T043) can be created in parallel
- Different user stories can be worked on in parallel by different team members after Foundation

---

## Parallel Example: Foundational Phase

```bash
# After T005-T007 complete (database), launch in parallel:
Task: "Create Edge Function scaffold" (T008)
Task: "Create base HTML template" (T009)
Task: "Create useReportGeneration hook" (T010)
Task: "Create useReportHistory hook" (T011)
Task: "Create report-config-form component" (T012)
Task: "Create report-progress component" (T013)
Task: "Create report-download component" (T014)
```

## Parallel Example: User Story 1

```bash
# After T016 (RPC function), launch in parallel:
Task: "Create timesheet HTML template" (T017)
Task: "Create client-side CSV export utility" (T020)

# Then sequentially:
Task: "Create timesheet generator module" (T018)
Task: "Create timesheet page" (T019)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T015) - CRITICAL
3. Complete Phase 3: User Story 1 - Timesheet Report (T016-T023)
4. **STOP and VALIDATE**: Test timesheet report independently
5. Deploy/demo - MVP complete!

### Incremental Delivery

1. Setup + Foundational -> Foundation ready
2. Add User Story 1 (Timesheet) -> Test -> Deploy (MVP!)
3. Add User Story 2 (Shift History) -> Test -> Deploy
4. Add User Story 3 (Activity Summary) -> Test -> Deploy
5. Add User Story 4 (Attendance) -> Test -> Deploy
6. Add User Story 5 (Scheduling) -> Test -> Deploy
7. Complete Phase 8 (Polish) -> Final release

### Single Developer Strategy

1. Complete Setup + Foundational
2. Implement stories in priority order: P1 -> P2 -> P2 -> P3 -> P4
3. Complete polish phase
4. Full validation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Migration file (T005-T007) should be created incrementally - add RPC functions as each story is implemented
- Browserless token required in environment variables before Edge Function testing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
