# Tasks: Mileage Tracking for Reimbursement

**Input**: Design documents from `/specs/017-mileage-tracking/`
**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md

**Tests**: Not explicitly requested — test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create feature module directories and barrel exports

- [X] T001 Create Flutter mileage feature directory structure: `gps_tracker/lib/features/mileage/{models,services,providers,screens,widgets}/`
- [X] T002 [P] Create dashboard mileage section structure: `dashboard/src/{app/dashboard/mileage/,components/mileage/,lib/hooks/,types/}`
- [X] T003 [P] Create barrel export file `gps_tracker/lib/features/mileage/mileage.dart` exporting all public APIs

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Database schema, core models, and shared types that ALL user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

### Database Migrations

- [X] T004 Create migration `supabase/migrations/032_mileage_trips.sql` with `trips` table, `trip_gps_points` junction table, indexes, and RLS policies per data-model.md
- [X] T005 [P] Create migration `supabase/migrations/033_reimbursement_rates.sql` with `reimbursement_rates` table, indexes, RLS, and seed row for CRA 2026 rate ($0.72/km first 5000 km, $0.66/km after)
- [X] T006 [P] Create migration `supabase/migrations/034_mileage_reports.sql` with `mileage_reports` table, indexes, and RLS policies per data-model.md
- [X] T007 Create migration `supabase/migrations/035_trip_detection_rpc.sql` with `detect_trips(p_shift_id UUID)` and `get_mileage_summary(p_employee_id, p_period_start, p_period_end)` PL/pgSQL functions per contracts/rpcs.md

### Flutter Models

- [X] T008 [P] Create Trip model in `gps_tracker/lib/features/mileage/models/trip.dart` with fromJson/toJson, TripClassification and TripDetectionMethod enums per contracts/types.md
- [X] T009 [P] Create MileageSummary model in `gps_tracker/lib/features/mileage/models/mileage_summary.dart` with fromJson per contracts/types.md
- [X] T010 [P] Create ReimbursementRate model in `gps_tracker/lib/features/mileage/models/reimbursement_rate.dart` with fromJson and `calculateReimbursement(km, ytdKm)` method per contracts/types.md
- [X] T011 [P] Create LocalTrip model in `gps_tracker/lib/features/mileage/models/local_trip.dart` with toMap/fromMap/toTrip/fromTrip conversions per contracts/types.md

### Local Database

- [X] T012 Create mileage local DB service in `gps_tracker/lib/features/mileage/services/mileage_local_db.dart` with `local_trips` SQLCipher table creation, CRUD operations, and sync status tracking (follow pattern from `gps_tracker/lib/shared/services/local_database.dart`)

### Dashboard Types

- [X] T013 [P] Create TypeScript types in `dashboard/src/types/mileage.ts` with Trip, MileageSummary, TeamMileageSummary, ReimbursementRate, MileageReport interfaces per contracts/types.md
- [X] T014 [P] Create Zod validation schemas in `dashboard/src/lib/validations/mileage.ts` with rateConfigSchema, mileageFiltersSchema, reportGenerationSchema per contracts/types.md

**Checkpoint**: Foundation ready — all tables, models, and types exist. User story implementation can begin.

---

## Phase 3: User Story 1 — Automatic Trip Detection During Shift (Priority: P1) MVP

**Goal**: When an employee clocks out, the system automatically analyzes their GPS points and detects vehicle trips (speed >15 km/h, sustained >2 min), filtering noise and short movements.

**Independent Test**: Clock in, drive between two locations (or simulate GPS points), clock out, then verify `trips` table contains a detected trip with correct start/end coordinates, distance, and duration.

### Implementation for User Story 1

- [X] T015 [US1] Create trip_service in `gps_tracker/lib/features/mileage/services/trip_service.dart` with `detectTrips(shiftId)` calling Supabase RPC `detect_trips`, `getTripsForShift(shiftId)`, and `getTripsForPeriod(employeeId, start, end)` methods
- [X] T016 [US1] Create reimbursement_rate_provider in `gps_tracker/lib/features/mileage/providers/reimbursement_rate_provider.dart` as a FutureProvider fetching the current active rate from `reimbursement_rates` table
- [X] T017 [US1] Create trip_provider in `gps_tracker/lib/features/mileage/providers/trip_provider.dart` with `tripsForShiftProvider(shiftId)` and `tripsForPeriodProvider(employeeId, start, end)` using trip_service
- [X] T018 [US1] Integrate trip detection into clock-out flow: add fire-and-forget `tripService.detectTrips(shiftId)` call after successful clock-out in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T019 [US1] Integrate trip re-detection after GPS sync: when offline GPS points sync successfully in `gps_tracker/lib/features/shifts/services/sync_service.dart`, call `detectTrips` for the affected shift

**Checkpoint**: Trips are automatically detected on clock-out. Data exists in the `trips` table. No UI yet — verify via Supabase dashboard or SQL query.

---

## Phase 4: User Story 2 — View Trip Details and Shift Mileage Summary (Priority: P1)

**Goal**: Employee can see all trips for a shift, view each trip on a map with route and addresses, and see total mileage/reimbursement summary for any period.

**Independent Test**: Complete a shift with at least one detected trip, navigate to shift details → Mileage tab, verify trips are listed with distance/duration/reimbursement. Tap a trip to see the route on a map with start/end markers and reverse-geocoded addresses.

### Implementation for User Story 2

- [X] T020 [US2] Create reverse_geocode_service in `gps_tracker/lib/features/mileage/services/reverse_geocode_service.dart` with lazy Nominatim geocoding (1 req/sec rate limit), cache result by updating `start_address`/`end_address` in `trips` table via Supabase
- [X] T021 [US2] Create mileage_summary_provider in `gps_tracker/lib/features/mileage/providers/mileage_summary_provider.dart` calling Supabase RPC `get_mileage_summary` with employee_id and date range
- [X] T022 [P] [US2] Create trip_card widget in `gps_tracker/lib/features/mileage/widgets/trip_card.dart` showing start/end address (or lat/lng fallback), distance km, duration, estimated reimbursement, and confidence badge
- [X] T023 [P] [US2] Create trip_route_map widget in `gps_tracker/lib/features/mileage/widgets/trip_route_map.dart` using google_maps_flutter to display trip polyline from trip_gps_points with start/end markers (follow pattern from `gps_tracker/lib/features/history/widgets/gps_route_map.dart`)
- [X] T024 [P] [US2] Create mileage_summary_card widget in `gps_tracker/lib/features/mileage/widgets/mileage_summary_card.dart` showing total km, total reimbursement, and trip count for a period
- [X] T025 [P] [US2] Create mileage_period_picker widget in `gps_tracker/lib/features/mileage/widgets/mileage_period_picker.dart` with presets (This Week, Last Week, This Pay Period, Custom) following date_range_picker pattern from dashboard feature
- [X] T026 [US2] Create mileage_screen in `gps_tracker/lib/features/mileage/screens/mileage_screen.dart` with period picker at top, mileage_summary_card, and scrollable list of trip_cards grouped by date
- [X] T027 [US2] Create trip_detail_screen in `gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart` with trip_route_map, trip metadata (addresses, distance, duration, confidence), and reverse-geocode trigger on load
- [X] T028 [US2] Add "Mileage" tab to existing shift detail view in `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart` showing trip list for that shift with per-shift mileage summary
- [X] T029 [US2] Add "Mileage" navigation entry to home screen in `gps_tracker/lib/features/home/home_screen.dart` (bottom nav tab or feature menu item) linking to mileage_screen

**Checkpoint**: Employee can navigate to Mileage from home, see trips for any period, tap into trip details with map and addresses. Shift detail now shows a Mileage tab.

---

## Phase 5: User Story 3 — Mileage Reimbursement Report Generation (Priority: P1)

**Goal**: Employee can select a date range, generate a PDF reimbursement report with all business trips, distances, rates, and totals, then share/export it.

**Independent Test**: Select a 2-week period with trips, tap "Generate Report", verify PDF opens with employee name, period, trip table (date, from, to, km, $), rate footnote, and grand total. Share via email or save to Files.

### Implementation for User Story 3

- [X] T030 [US3] Create mileage_report_service in `gps_tracker/lib/features/mileage/services/mileage_report_service.dart` generating PDF using `pdf` package (follow pattern from `gps_tracker/lib/features/history/services/export_service.dart`): A4 format, employee name, period, trip table, per-trip reimbursement, rate footnote, grand total, and save record to `mileage_reports` table
- [X] T031 [P] [US3] Create report_share_sheet widget in `gps_tracker/lib/features/mileage/widgets/report_share_sheet.dart` as a bottom sheet with "Share" (system share sheet via share_plus), "Save to Device", format indicator, and loading state
- [X] T032 [US3] Create mileage_report_screen in `gps_tracker/lib/features/mileage/screens/mileage_report_screen.dart` with date range picker, trip preview list, total distance/reimbursement summary, "Generate Report" button triggering mileage_report_service, and report_share_sheet on completion
- [X] T033 [US3] Add "Generate Report" action button to mileage_screen in `gps_tracker/lib/features/mileage/screens/mileage_screen.dart` navigating to mileage_report_screen with current period pre-filled

**Checkpoint**: Employee can generate and share PDF mileage reimbursement reports. This completes the core employee-facing value proposition and App Store justification.

---

## Phase 6: User Story 4 — Personal vs. Business Trip Classification (Priority: P2)

**Goal**: Employee can toggle any trip between "Business" and "Personal". Personal trips are excluded from reimbursement totals and reports. All trips default to "Business".

**Independent Test**: View trips for a shift, long-press a trip, toggle to "Personal", verify mileage summary updates (total reimbursable km decreases), generate report and confirm personal trip is excluded.

### Implementation for User Story 4

- [X] T034 [P] [US4] Create trip_classification_chip widget in `gps_tracker/lib/features/mileage/widgets/trip_classification_chip.dart` as a tappable chip showing "Business" (green) or "Personal" (grey) with toggle action
- [X] T035 [US4] Add `updateTripClassification(tripId, classification)` method to trip_service in `gps_tracker/lib/features/mileage/services/trip_service.dart` updating the `classification` column via Supabase (RLS allows employee to update own trips only)
- [X] T036 [US4] Integrate trip_classification_chip into trip_card widget in `gps_tracker/lib/features/mileage/widgets/trip_card.dart` and trip_detail_screen, with optimistic update and provider refresh on toggle
- [X] T037 [US4] Add classification filter to mileage_screen in `gps_tracker/lib/features/mileage/screens/mileage_screen.dart`: filter chips for "All", "Business", "Personal" above trip list, and ensure mileage_summary_card reflects filtered view

**Checkpoint**: Trip classification works end-to-end. Personal trips visually distinct and excluded from reports.

---

## Phase 7: User Story 5 — Manager Views Team Mileage Dashboard (Priority: P2)

**Goal**: Manager can view team mileage summaries, drill into individual employees, and export team mileage reports (CSV/PDF) from the web dashboard.

**Independent Test**: Log in as manager on the dashboard, navigate to Mileage tab, verify supervised employees appear with total km and reimbursement for selected period. Click an employee to see their trips. Export team CSV.

### Database & Backend

- [ ] T038 [US5] Create migration `supabase/migrations/036_team_mileage_rpc.sql` with `get_team_mileage_summary(p_period_start, p_period_end)` PL/pgSQL function that aggregates trips for supervised employees per contracts/rpcs.md

### Dashboard Hooks & Utils

- [ ] T039 [P] [US5] Create use-trips hook in `dashboard/src/lib/hooks/use-trips.ts` using Refine useList to fetch trips with employee/shift filters, pagination, and date range
- [ ] T040 [P] [US5] Create use-mileage-summary hook in `dashboard/src/lib/hooks/use-mileage-summary.ts` calling Supabase RPC `get_team_mileage_summary` and `get_mileage_summary` with typed responses
- [ ] T041 [P] [US5] Create use-reimbursement-rates hook in `dashboard/src/lib/hooks/use-reimbursement-rates.ts` using Refine useList/useOne for rate CRUD

### Dashboard Components

- [ ] T042 [P] [US5] Create mileage-summary-cards component in `dashboard/src/components/mileage/mileage-summary-cards.tsx` with KPI cards: total team km, total reimbursement, trip count, avg km/employee (shadcn Card)
- [ ] T043 [P] [US5] Create mileage-filters component in `dashboard/src/components/mileage/mileage-filters.tsx` with date range picker (reuse date-range-selector pattern), employee selector, classification filter (shadcn Select + Popover)
- [ ] T044 [P] [US5] Create team-mileage-table component in `dashboard/src/components/mileage/team-mileage-table.tsx` with @tanstack/react-table: columns for employee name, total km, business km, trip count, reimbursement, avg daily km — sortable and filterable
- [ ] T045 [P] [US5] Create trip-table component in `dashboard/src/components/mileage/trip-table.tsx` with columns: date, start→end address, distance, duration, classification, confidence — for individual employee drill-down
- [ ] T046 [P] [US5] Create trip-route-map component in `dashboard/src/components/mileage/trip-route-map.tsx` using react-leaflet to render trip polyline with start/end markers (follow pattern from `dashboard/src/components/monitoring/gps-trail-map.tsx`)
- [ ] T047 [P] [US5] Create employee-mileage-detail component in `dashboard/src/components/mileage/employee-mileage-detail.tsx` composing mileage-summary-cards + trip-table + trip-route-map for a single employee
- [ ] T048 [P] [US5] Create team-export-dialog component in `dashboard/src/components/mileage/team-export-dialog.tsx` with format selector (CSV/PDF), date range, employee selection, and download trigger (follow pattern from `dashboard/src/components/history/export-dialog.tsx`)

### Dashboard Pages & Navigation

- [ ] T049 [US5] Create team mileage page in `dashboard/src/app/dashboard/mileage/page.tsx` composing mileage-filters, mileage-summary-cards, team-mileage-table, and team-export-dialog
- [ ] T050 [US5] Create employee mileage detail page in `dashboard/src/app/dashboard/mileage/[employeeId]/page.tsx` composing employee-mileage-detail with breadcrumb navigation back to team view
- [ ] T051 [US5] Add "Mileage" entry to dashboard sidebar in `dashboard/src/components/layout/sidebar.tsx` after existing "Reports" item, with a mileage/odometer icon

**Checkpoint**: Manager can view team mileage, drill into employees, and export reports from the web dashboard.

---

## Phase 8: User Story 6 — Configure Reimbursement Rate (Priority: P3)

**Goal**: Admin can set a custom per-km reimbursement rate (or use CRA default). Rate changes apply to future calculations only.

**Independent Test**: Log in as admin on dashboard, open rate configuration, change rate to $0.50/km, save. Generate a new mileage summary and verify it uses the new rate. Check old reports still show old rate.

### Database & Backend

- [ ] T052 [US6] Create migration `supabase/migrations/037_rate_management_rpc.sql` with `upsert_reimbursement_rate()` PL/pgSQL function that validates admin role, sets `effective_to` on previous rate, inserts new rate per contracts/rpcs.md

### Dashboard Components & Integration

- [ ] T053 [P] [US6] Create rate-config-dialog component in `dashboard/src/components/mileage/rate-config-dialog.tsx` as a shadcn Dialog with form: rate_per_km, threshold_km (optional), rate_after_threshold (optional), effective_from date, rate_source (CRA/Custom), notes — validated with rateConfigSchema from Zod
- [ ] T054 [US6] Add rate configuration trigger to team mileage page in `dashboard/src/app/dashboard/mileage/page.tsx`: "Configure Rate" button (visible to admins only) opening rate-config-dialog, with current rate displayed in page header
- [ ] T055 [US6] Display current rate info on mileage_screen in `gps_tracker/lib/features/mileage/screens/mileage_screen.dart`: small info text below summary card showing "Rate: $0.72/km (CRA 2026)" from reimbursement_rate_provider

**Checkpoint**: Admins can configure rates. Rate is visible to employees. Historical reports unaffected.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Offline resilience, edge cases, and integration polish

- [X] T056 Implement offline trip caching in `gps_tracker/lib/features/mileage/services/trip_service.dart`: after fetching trips from Supabase, cache to `local_trips` via mileage_local_db; when offline, serve from local cache; sync classification changes when connectivity returns
- [X] T057 [P] Add low-confidence trip warning badge to trip_card in `gps_tracker/lib/features/mileage/widgets/trip_card.dart`: show amber warning icon when `confidence_score < 0.7` with tooltip explaining estimated segments
- [X] T058 [P] Add empty states to mileage_screen and mileage_report_screen: "No trips detected" illustration when no trips exist for the selected period, with explanatory text about trip detection requirements (shifts with GPS tracking)
- [X] T059 Update Info.plist location usage description in `gps_tracker/ios/Runner/Info.plist`: update `NSLocationAlwaysAndWhenInUseUsageDescription` to mention mileage tracking as an employee benefit (e.g., "Tri-Logis Clock uses your location to automatically track work trips for mileage reimbursement and to record your work location during shifts.")
- [X] T060 Update barrel export in `gps_tracker/lib/features/mileage/mileage.dart` to include all models, services, providers, screens, and widgets created across all phases

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Phase 2 — MVP core, must complete first
- **US2 (Phase 4)**: Depends on Phase 3 (trips must exist to display them)
- **US3 (Phase 5)**: Depends on Phase 4 (needs mileage screen + summary for report context)
- **US4 (Phase 6)**: Depends on Phase 4 (needs trip_card and mileage_screen to add classification UI)
- **US5 (Phase 7)**: Depends on Phase 2 only (dashboard is independent of mobile UI, but needs trip data from US1)
- **US6 (Phase 8)**: Depends on Phase 7 (rate config goes on dashboard mileage page)
- **Polish (Phase 9)**: Depends on all desired stories being complete

### User Story Dependencies

```
Phase 1 (Setup)
  └── Phase 2 (Foundational)
        ├── Phase 3 (US1: Trip Detection) ──┐
        │     └── Phase 4 (US2: View Trips) ├── Phase 9 (Polish)
        │           ├── Phase 5 (US3: Reports)
        │           └── Phase 6 (US4: Classification)
        └── Phase 7 (US5: Manager Dashboard)
              └── Phase 8 (US6: Rate Config)
```

### Within Each User Story

- Models before services (already in Phase 2)
- Services before providers
- Providers before screens
- Widgets before screens that compose them
- Core implementation before integration hooks

### Parallel Opportunities

- **Phase 1**: T001, T002, T003 all in parallel
- **Phase 2**: T004→T007 (migrations sequential), T008-T011 (models parallel), T013-T014 (TS types parallel)
- **Phase 4**: T022-T025 (widgets all parallel), then T026-T027 (screens)
- **Phase 7**: T039-T041 (hooks parallel), T042-T048 (components all parallel), then T049-T051 (pages)
- **Cross-phase**: Phase 7 (US5 dashboard) can run in parallel with Phases 4-6 (mobile UI) since they touch different codebases

---

## Parallel Example: User Story 2

```bash
# Launch all widgets in parallel (different files, no dependencies):
Task: "Create trip_card widget in gps_tracker/lib/features/mileage/widgets/trip_card.dart"
Task: "Create trip_route_map widget in gps_tracker/lib/features/mileage/widgets/trip_route_map.dart"
Task: "Create mileage_summary_card widget in gps_tracker/lib/features/mileage/widgets/mileage_summary_card.dart"
Task: "Create mileage_period_picker widget in gps_tracker/lib/features/mileage/widgets/mileage_period_picker.dart"

# Then launch screens (depend on widgets):
Task: "Create mileage_screen in gps_tracker/lib/features/mileage/screens/mileage_screen.dart"
Task: "Create trip_detail_screen in gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart"
```

## Parallel Example: User Story 5 (Dashboard)

```bash
# Launch all hooks in parallel:
Task: "Create use-trips hook in dashboard/src/lib/hooks/use-trips.ts"
Task: "Create use-mileage-summary hook in dashboard/src/lib/hooks/use-mileage-summary.ts"
Task: "Create use-reimbursement-rates hook in dashboard/src/lib/hooks/use-reimbursement-rates.ts"

# Launch all components in parallel (7 independent components):
Task: "Create mileage-summary-cards in dashboard/src/components/mileage/mileage-summary-cards.tsx"
Task: "Create mileage-filters in dashboard/src/components/mileage/mileage-filters.tsx"
Task: "Create team-mileage-table in dashboard/src/components/mileage/team-mileage-table.tsx"
Task: "Create trip-table in dashboard/src/components/mileage/trip-table.tsx"
Task: "Create trip-route-map in dashboard/src/components/mileage/trip-route-map.tsx"
Task: "Create employee-mileage-detail in dashboard/src/components/mileage/employee-mileage-detail.tsx"
Task: "Create team-export-dialog in dashboard/src/components/mileage/team-export-dialog.tsx"

# Then pages (depend on components):
Task: "Create team mileage page in dashboard/src/app/dashboard/mileage/page.tsx"
Task: "Create employee detail page in dashboard/src/app/dashboard/mileage/[employeeId]/page.tsx"
```

---

## Implementation Strategy

### MVP First (User Stories 1-3 = App Store Submission)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (migrations, models, types)
3. Complete Phase 3: US1 — Trip Detection (core algorithm)
4. Complete Phase 4: US2 — View Trips (employee sees their trips)
5. Complete Phase 5: US3 — Reports (employee generates reimbursement PDF)
6. **STOP and VALIDATE**: The app now has a compelling employee-facing mileage feature
7. **Submit to Apple**: This is the minimum needed to address Guideline 2.5.4 rejection

### Incremental Delivery

1. **MVP** (Phases 1-5): Trip detection + view + reports → App Store submission
2. **+Classification** (Phase 6): Business/personal toggle → Better accuracy
3. **+Manager Dashboard** (Phases 7-8): Team mileage + rate config → Manager value
4. **+Polish** (Phase 9): Offline, edge cases, empty states → Production quality

### Cross-Platform Parallelism

The mobile (Phases 3-6) and dashboard (Phase 7) codebases are independent after Phase 2. A team can work on both simultaneously:

- **Mobile developer**: Phases 3 → 4 → 5 → 6 → 9
- **Dashboard developer**: Phase 7 → 8

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Migration numbering starts at 032 (last applied: 031_phone_auth)
- The `detect_trips()` RPC is the most complex single task — budget extra time for the PL/pgSQL trip detection algorithm
- Reverse geocoding (Nominatim) has a 1 req/sec rate limit — the lazy approach avoids bulk calls
- PDF report generation reuses the existing `pdf` package and patterns from spec 006
- Dashboard components follow existing patterns from specs 009-013 (shadcn/ui, Refine hooks, react-leaflet)
