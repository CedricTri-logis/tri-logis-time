# Tasks: Cleaning Session Tracking via QR Code

**Input**: Design documents from `/specs/016-cleaning-qr-tracking/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Add new dependency, configure platform permissions

- [x] T001 Add `mobile_scanner: ^7.1.4` dependency in `gps_tracker/pubspec.yaml` and run `flutter pub get`
- [x] T002 [P] Add CAMERA permission to `gps_tracker/android/app/src/main/AndroidManifest.xml` — add `<uses-permission android:name="android.permission.CAMERA" />`
- [x] T003 [P] Add ML Kit ProGuard rules to `gps_tracker/android/app/proguard-rules.pro` — add `-keep class com.google.mlkit.vision.barcode.** { *; }` and `-keep class com.google.mlkit.vision.common.** { *; }`
- [x] T004 [P] Add `NSCameraUsageDescription` to `gps_tracker/ios/Runner/Info.plist` with message "Camera access is needed to scan QR codes for room check-in and check-out."

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Database schema, seed data, Flutter models, and local storage — MUST complete before any user story

**CRITICAL**: No user story work can begin until this phase is complete

### Database Migration

- [x] T005 Create Supabase migration `supabase/migrations/016_cleaning_qr_tracking.sql` — Part 1: Create `studio_type` enum (`unit`, `common_area`, `conciergerie`), `cleaning_session_status` enum (`in_progress`, `completed`, `auto_closed`, `manually_closed`), `buildings` table (id, name, created_at, updated_at), `studios` table (id, qr_code UNIQUE, studio_number, building_id FK, studio_type, is_active, created_at, updated_at) with unique constraint on (building_id, studio_number), and `cleaning_sessions` table (id, employee_id FK, studio_id FK, shift_id FK, status, started_at, completed_at, duration_minutes, is_flagged, flag_reason, created_at, updated_at) with constraints (completed_at > started_at, duration_minutes >= 0), indexes on (employee_id, status), (studio_id, started_at), (shift_id), partial index on status WHERE status = 'in_progress', triggers for updated_at auto-update on all three tables. See data-model.md for full schema.
- [x] T006 Extend migration `supabase/migrations/016_cleaning_qr_tracking.sql` — Part 2: Add RLS policies. Buildings and studios: all authenticated can SELECT, only admin/super_admin can INSERT/UPDATE/DELETE. Cleaning sessions: employees can SELECT/INSERT/UPDATE own sessions, supervisors (manager+) can SELECT/UPDATE supervised employee sessions, admin/super_admin full access. See data-model.md RLS Policies section.
- [x] T007 Extend migration `supabase/migrations/016_cleaning_qr_tracking.sql` — Part 3: Create RPC functions `scan_in(p_employee_id, p_qr_code, p_shift_id)`, `scan_out(p_employee_id, p_qr_code)`, `auto_close_shift_sessions(p_shift_id, p_employee_id, p_closed_at)`, `get_active_session(p_employee_id)` per contracts/supabase-rpc.md. Include duration flagging logic: flag if <5 min for unit, <2 min for common_area/conciergerie, or >240 min for any type.
- [x] T008 Extend migration `supabase/migrations/016_cleaning_qr_tracking.sql` — Part 4: Create RPC functions `get_cleaning_dashboard(p_building_id, p_employee_id, p_date_from, p_date_to, p_limit, p_offset)`, `get_cleaning_stats_by_building(p_date_from, p_date_to)`, `get_employee_cleaning_stats(p_employee_id, p_date_from, p_date_to)`, `manually_close_session(p_session_id, p_closed_by)` per contracts/supabase-rpc.md. Dashboard RPCs must join cleaning_sessions + studios + buildings + employee_profiles.
- [x] T009 Extend migration `supabase/migrations/016_cleaning_qr_tracking.sql` — Part 5: Seed all 10 buildings and ~115 studios with QR codes from user-provided data. Buildings: Le Citadin, Le Cardinal, Le Chic-urbain, Le Contemporain, Le Cinq Étoiles, Le Central, Le Court-toit, Le Centre-Ville, Le Convivial, Le Chambreur. Studios include rental units (type `unit`), common areas (type `common_area`), and conciergerie entries (type `conciergerie`). Use exact QR code IDs from spec (e.g., 8FJ3K2L9H4 → Studio 201, Le Citadin). Full QR mapping data is in the original user input in the spec.

### Flutter Models

- [x] T010 [P] Create Studio model in `gps_tracker/lib/features/cleaning/models/studio.dart` — immutable class with fields: id, qrCode, studioNumber, buildingId, buildingName, studioType (StudioType enum: unit, commonArea, conciergerie), isActive. Include fromJson/toJson, fromLocalDb/toLocalDb factory methods. Follow the same pattern as `Shift` model in `gps_tracker/lib/shared/models/`.
- [x] T011 [P] Create CleaningSession model in `gps_tracker/lib/features/cleaning/models/cleaning_session.dart` — immutable class with fields: id, employeeId, studioId, shiftId, status (CleaningSessionStatus enum: inProgress, completed, autoClosed, manuallyClosed), startedAt, completedAt, durationMinutes, isFlagged, flagReason, syncStatus (reuse SyncStatus from shared/models), studioNumber, buildingName, studioType (denormalized for display). Include fromJson/toJson, fromLocalDb/toLocalDb, computed `duration` getter. See contracts/flutter-services.md Models section.
- [x] T012 [P] Create ScanResult model in `gps_tracker/lib/features/cleaning/models/scan_result.dart` — class with fields: success, session (CleaningSession?), errorType (ScanErrorType enum: invalidQr, studioInactive, noActiveShift, sessionExists, noActiveSession), errorMessage, existingSessionId, warning. See contracts/flutter-services.md.

### Local Database Extension

- [x] T013 Extend local database in `gps_tracker/lib/shared/services/local_database.dart` (or create `gps_tracker/lib/features/cleaning/services/cleaning_local_db.dart`) — Add `local_studios` table (id TEXT PK, qr_code TEXT UNIQUE, studio_number TEXT, building_id TEXT, building_name TEXT, studio_type TEXT, is_active INTEGER, updated_at TEXT) and `local_cleaning_sessions` table (id TEXT PK, employee_id TEXT, studio_id TEXT, shift_id TEXT, status TEXT, started_at TEXT, completed_at TEXT, duration_minutes REAL, is_flagged INTEGER, flag_reason TEXT, sync_status TEXT, server_id TEXT, created_at TEXT, updated_at TEXT) with indexes. Increment database version. Add CRUD methods: insertStudio, getStudioByQrCode, getAllStudios, upsertStudios, insertCleaningSession, updateCleaningSession, getActiveSessionForEmployee, getSessionsForShift, getPendingCleaningSessions, markCleaningSessionSynced. See data-model.md Local Storage section.

### Studio Cache Service

- [x] T014 Create StudioCacheService in `gps_tracker/lib/features/cleaning/services/studio_cache_service.dart` — Methods: syncStudios() downloads all active studios from Supabase (SELECT studios JOIN buildings) and upserts into local_studios table; lookupByQrCode(qrCode) returns Studio? from local cache; getAllStudios() returns List<Studio> for manual entry fallback. Follow same pattern as existing services using SupabaseClient + LocalDatabase. See contracts/flutter-services.md.

**Checkpoint**: Foundation ready — database deployed, models defined, local storage extended, studio cache available

---

## Phase 3: User Story 1+2 — Scan In & Scan Out (Priority: P1) MVP

**Goal**: Employee can scan a QR code to start cleaning (scan-in) and scan again to complete cleaning (scan-out). This is the core feature loop.

**Independent Test**: Clock in to a shift → open scanner → scan a QR code → see session created with studio name and timer → scan same QR code again → see session completed with duration displayed

### Implementation

- [x] T015 Create CleaningSessionService in `gps_tracker/lib/features/cleaning/services/cleaning_session_service.dart` — Local-first service with methods: scanIn(employeeId, qrCode, shiftId) → ScanResult, scanOut(employeeId, qrCode) → ScanResult. scanIn flow: lookup studio by QR in local cache → if not found try Supabase → validate active studio → check no existing active session for this studio → create local_cleaning_session with status in_progress → attempt Supabase RPC scan_in → return result. scanOut flow: lookup studio → find active local session for employee+studio → update completed_at/duration/status to completed → apply flagging logic (unit <5min, common_area/conciergerie <2min, any >240min) → attempt Supabase RPC scan_out → return result. Follow same pattern as ShiftService. See contracts/flutter-services.md and contracts/supabase-rpc.md.
- [x] T016 Create CleaningSessionProvider in `gps_tracker/lib/features/cleaning/providers/cleaning_session_provider.dart` — Riverpod StateNotifierProvider managing CleaningSessionState (activeSession: CleaningSession?, isScanning: bool, error: String?). Methods: scanIn(qrCode), scanOut(qrCode), loadActiveSession(). Create derived providers: `activeCleaningSessionProvider` (returns current active session), `hasActiveCleaningSessionProvider` (bool). Also create `studioCacheProvider` for StudioCacheService. Follow same pattern as shift_provider.dart.
- [x] T017 Create QR Scanner Screen in `gps_tracker/lib/features/cleaning/screens/qr_scanner_screen.dart` — Full-screen camera view using MobileScannerController with formats: [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates. Implement WidgetsBindingObserver for camera lifecycle (pause on app background, resume on foreground). On barcode detected: check if active session exists for scanned studio → if yes, call scanOut → if no, call scanIn. Show scan result dialog. Include torch toggle button and manual entry fallback button. Handle camera permission denial with guidance. See research.md R-001 for mobile_scanner usage patterns.
- [x] T018 Create ScanResultDialog widget in `gps_tracker/lib/features/cleaning/widgets/scan_result_dialog.dart` — Modal dialog shown after scanning. For scan-in success: show studio name, building, "Session started" with green check, dismiss to return to main screen. For scan-out success: show studio name, building, duration formatted as "Xh Ym", "Session completed" with green check, warning text if flagged. For errors: show error icon and message (invalid QR, no active shift, studio inactive). For existing session warning: show "You have an active session at [room]. Close it first?" with "Close & Start New" and "Cancel" buttons.
- [x] T019 Create ManualEntryDialog widget in `gps_tracker/lib/features/cleaning/widgets/manual_entry_dialog.dart` — Bottom sheet dialog with text input for QR code ID, submit button. On submit: validate non-empty, call the same scanIn/scanOut logic as camera scan. Show autocomplete suggestions from local studios list if possible. Accessible from QR scanner screen via a button.

**Checkpoint**: Employees can scan QR codes to start and complete cleaning sessions. Core loop is functional.

---

## Phase 4: User Story 3 — View Active Cleaning Session (Priority: P1)

**Goal**: Employee sees their current active cleaning session with live timer on the main shift dashboard screen

**Independent Test**: Start a cleaning session → return to main screen → see studio name, building, and live running timer. No active session → see "Scan QR to start cleaning" prompt.

### Implementation

- [x] T020 Create ActiveSessionCard widget in `gps_tracker/lib/features/cleaning/widgets/active_session_card.dart` — ConsumerWidget showing current active cleaning session. Displays: studio number + building name as title, studio type badge, start time, live duration counter (updating every second like ShiftTimer), sync status indicator (pending/synced/error icon, following the same pattern as shift sync indicators). Shows "Scan QR to finish" prompt. When no active session: shows prompt card with scan icon and "Scan a QR code to start cleaning" text with a button to open scanner. Follow the visual style of ShiftStatusCard.
- [x] T021 Integrate ActiveSessionCard into `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart` — Add ActiveSessionCard below the existing ShiftStatusCard when employee has an active shift. Add a floating action button or prominent "Scan" button to open QR scanner screen. Only show cleaning UI when shift is active. Import cleaning providers and watch activeCleaningSessionProvider.
- [x] T022 Hook auto-close into shift clock-out in `gps_tracker/lib/features/shifts/providers/shift_provider.dart` — After successful clockOut() (when result.success is true), call CleaningSessionService.autoCloseSessions(shiftId, employeeId, clockedOutAt). Add autoCloseSessions method to CleaningSessionService that: finds all in_progress local sessions for the shift, sets completed_at to clockedOutAt, computes duration, sets status to auto_closed, applies flagging, syncs to Supabase via RPC auto_close_shift_sessions. See research.md R-003 for hook point details.

**Checkpoint**: Active cleaning session is visible on main screen with live timer. Sessions auto-close when shift ends.

---

## Phase 5: User Story 4 — View Cleaning History for Current Shift (Priority: P2)

**Goal**: Employee can see a list of all rooms cleaned during their current shift

**Independent Test**: Complete multiple cleaning sessions → view shift history → see all sessions with room names, durations, and statuses in chronological order

### Implementation

- [x] T023 Add getShiftSessions method to CleaningSessionService in `gps_tracker/lib/features/cleaning/services/cleaning_session_service.dart` — Query local_cleaning_sessions by shift_id, join with local_studios for display names, order by started_at DESC. Return List<CleaningSession>.
- [x] T024 Create shiftCleaningSessionsProvider in `gps_tracker/lib/features/cleaning/providers/cleaning_session_provider.dart` — FutureProvider.family that takes shiftId and returns List<CleaningSession> via getShiftSessions. Auto-refresh when active session changes.
- [x] T025 Create CleaningHistoryList widget in `gps_tracker/lib/features/cleaning/widgets/cleaning_history_list.dart` — ListView showing all cleaning sessions for current shift. Each item shows: studio number + building name, status badge (completed=green, in_progress=blue, auto_closed=orange), duration (or live counter if in progress), start time, flag indicator if flagged, sync status indicator (pending/synced/error). Empty state: "No rooms cleaned yet this shift." Follow visual patterns from existing shift history widgets.
- [x] T026 Integrate CleaningHistoryList into shift dashboard in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart` — Add a "Cleaning History" section or tab below the active session card. Show when shift is active. Display count of completed sessions as a badge/subtitle.

**Checkpoint**: Employees can view their complete cleaning history for the current shift.

---

## Phase 6: User Story 5 — Dashboard: Cleaning Sessions Overview (Priority: P2)

**Goal**: Supervisors see a cleaning activity dashboard with summary stats, filterable session list, and per-building breakdowns

**Independent Test**: Open dashboard → navigate to Cleaning → see today's stats (rooms cleaned, in progress, avg duration) → filter by building → see only that building's sessions → manually close an orphaned session

### Implementation

- [x] T027 [P] Create TypeScript types in `dashboard/src/types/cleaning.ts` — Define CleaningSessionStatus, StudioType, CleaningSessionRow, CleaningSession, CleaningSummary, BuildingStats, EmployeeCleaningStats interfaces. Add transformCleaningSessionRow(row) function converting snake_case to camelCase. See contracts/dashboard-hooks.md Types section.
- [x] T028 [P] Create Zod validation schemas in `dashboard/src/lib/validations/cleaning.ts` — Define cleaningFiltersSchema (buildingId optional uuid, employeeId optional uuid, dateFrom date, dateTo date, status optional enum), manualCloseSchema (sessionId uuid, reason optional string max 500). See contracts/dashboard-hooks.md Validation section.
- [x] T029 Create data hooks in `dashboard/src/lib/hooks/use-cleaning-sessions.ts` — useCleaningSessions(filters): calls RPC get_cleaning_dashboard via useCustom, returns sessions[], summary, totalCount, isLoading, refetch. useCleaningStatsByBuilding(dateFrom, dateTo): calls RPC get_cleaning_stats_by_building. useCleaningSessionMutations(): closeSession calls RPC manually_close_session. Follow same patterns as use-locations.ts (useCustom from Refine, transform rows, memoize). See contracts/dashboard-hooks.md.
- [x] T030 [P] Create BuildingStatsCards component in `dashboard/src/components/cleaning/building-stats-cards.tsx` — Grid of cards, one per building, showing: building name, rooms cleaned / total rooms, in-progress count, avg duration. Use shadcn Card component. Color-coded progress indicator (green if all cleaned, yellow if in-progress, gray if not started).
- [x] T031 [P] Create CleaningFilters component in `dashboard/src/components/cleaning/cleaning-filters.tsx` — Filter bar with: date range picker (dateFrom, dateTo, default today), building dropdown (populated from buildings data), employee dropdown (populated from supervised employees), status dropdown (all, in_progress, completed, auto_closed, manually_closed), clear filters button. Use shadcn Select, DatePicker components.
- [x] T032 [P] Create CleaningSessionsTable component in `dashboard/src/components/cleaning/cleaning-sessions-table.tsx` — Table showing cleaning sessions with columns: employee name, studio number, building, status badge, started at, completed at, duration, flagged indicator. Sortable by duration and started_at. Pagination. Row click could expand details. Use @tanstack/react-table + shadcn Table. Include "Close Session" action button for in_progress rows (supervisor only).
- [x] T033 [P] Create CloseSessionDialog component in `dashboard/src/components/cleaning/close-session-dialog.tsx` — Confirmation dialog for manually closing a session. Shows session details (employee, room, duration so far), optional reason text input. Confirm button calls closeSession mutation. Uses shadcn AlertDialog.
- [x] T034 Create Cleaning dashboard page in `dashboard/src/app/dashboard/cleaning/page.tsx` — Main page composing: page header with title "Cleaning" + total count, CleaningFilters, summary stats row (total sessions, completed, in-progress, avg duration, flagged), BuildingStatsCards section, CleaningSessionsTable with pagination. Wire up useCleaningSessions and useCleaningStatsByBuilding hooks. Follow same structure as locations/page.tsx.
- [x] T035 Add "Cleaning" navigation item to sidebar in `dashboard/src/components/layout/sidebar.tsx` — Add entry: { name: 'Cleaning', href: '/dashboard/cleaning', icon: SprayCan } (from lucide-react). Place between "Locations" and "Reports" in the navigation array.

**Checkpoint**: Supervisors can view cleaning activity, filter by building/employee/date, and manually close orphaned sessions.

---

## Phase 7: User Story 6 — Dashboard: Cleaning Analytics (Priority: P3)

**Goal**: Supervisors can view detailed cleaning statistics per studio and per employee

**Independent Test**: Navigate to cleaning dashboard → see per-building stats → click for detailed employee performance view with avg duration and session counts

### Implementation

- [x] T036 Add useEmployeeCleaningStats hook in `dashboard/src/lib/hooks/use-cleaning-sessions.ts` — Calls RPC get_employee_cleaning_stats(p_employee_id, p_date_from, p_date_to). Returns EmployeeCleaningStats with totalSessions, avgDurationMinutes, sessionsByBuilding breakdown, flaggedSessions. See contracts/dashboard-hooks.md.
- [x] T037 Extend CleaningSessionsTable in `dashboard/src/components/cleaning/cleaning-sessions-table.tsx` — Add expandable row detail showing: per-employee summary when grouped by employee (total sessions, avg time, buildings breakdown), per-studio summary when grouped by studio (cleaning frequency, avg duration, last cleaned date). Add group-by toggle (none/employee/building).
- [x] T038 Extend Cleaning dashboard page `dashboard/src/app/dashboard/cleaning/page.tsx` — Add analytics section below the sessions table: employee performance summary cards showing top cleaners, avg duration by employee, flagged session ratio. Add building summary section showing cleaning completion rates and trends. Wire up useEmployeeCleaningStats hook.

**Checkpoint**: Full analytics visible — per-building completion rates, per-employee performance, duration analysis.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Sync, edge cases, and production readiness

- [x] T039 Add syncPendingSessions method to CleaningSessionService in `gps_tracker/lib/features/cleaning/services/cleaning_session_service.dart` — Query local sessions with sync_status = 'pending', attempt Supabase sync for each (scan_in or scan_out RPC depending on session state), update sync_status on success/error. Call on app resume and connectivity change (hook into existing connectivity monitoring).
- [x] T040 Add studio cache sync and active session recovery on app start in `gps_tracker/lib/main.dart` or appropriate initialization point — Call StudioCacheService.syncStudios() during app initialization (after Supabase init). Also call CleaningSessionProvider.loadActiveSession() to restore any in-progress cleaning session from local storage (handles app restart/crash recovery). Handle errors gracefully (offline: use cached data, no cache: show error on first scan).
- [x] T041 Handle unclosed session warning in QR scanner — When employee scans a DIFFERENT room while having an active session, show a dialog: "You have an active session at [room]. Close it and start new?" with options "Close & Scan New" (auto-close + scan-in) and "Cancel" (return to scanner). Implement in `gps_tracker/lib/features/cleaning/screens/qr_scanner_screen.dart`.
- [x] T042 Validate no-shift guard in QR scanner — When employee opens scanner without an active shift, show error and redirect to shift dashboard with message "Clock in first to start cleaning." Implement in `gps_tracker/lib/features/cleaning/screens/qr_scanner_screen.dart` by checking hasActiveShiftProvider on screen mount.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup (T001 for models to reference mobile_scanner types) — BLOCKS all user stories
- **US1+US2 (Phase 3)**: Depends on Foundational (T005-T014) — core feature loop
- **US3 (Phase 4)**: Depends on US1+US2 (needs active session to display)
- **US4 (Phase 5)**: Depends on US1+US2 (needs completed sessions to list)
- **US5 (Phase 6)**: Depends on Foundational (T005-T009 for RPC functions) — can run in parallel with Phases 3-5 (different codebase: dashboard vs Flutter)
- **US6 (Phase 7)**: Depends on US5 (extends dashboard components)
- **Polish (Phase 8)**: Depends on Phases 3-4

### User Story Dependencies

- **US1+US2 (P1)**: Can start after Foundational — core MVP
- **US3 (P1)**: Can start after US1+US2 — needs active session provider
- **US4 (P2)**: Can start after US1+US2 — needs session history
- **US5 (P2)**: Can start after Foundational — independent dashboard work, parallelizable with Flutter phases
- **US6 (P3)**: Can start after US5 — extends dashboard
- **Polish**: After US1-US4

### Within Each User Story

- Models before services
- Services before providers
- Providers before screens/widgets
- Core implementation before integration with existing screens

### Parallel Opportunities

- T002, T003, T004 — platform config (different files)
- T010, T011, T012 — Flutter models (different files)
- T027, T028 — Dashboard types and validations (different files)
- T030, T031, T032, T033 — Dashboard components (different files)
- **Phase 6 (Dashboard) can run in parallel with Phases 3-5 (Flutter)** — different codebases entirely

---

## Parallel Example: Phase 6 (Dashboard)

```bash
# Launch all independent dashboard components together:
Task: "Create types in dashboard/src/types/cleaning.ts"
Task: "Create validations in dashboard/src/lib/validations/cleaning.ts"

# Then after types/validations:
Task: "Create BuildingStatsCards in dashboard/src/components/cleaning/building-stats-cards.tsx"
Task: "Create CleaningFilters in dashboard/src/components/cleaning/cleaning-filters.tsx"
Task: "Create CleaningSessionsTable in dashboard/src/components/cleaning/cleaning-sessions-table.tsx"
Task: "Create CloseSessionDialog in dashboard/src/components/cleaning/close-session-dialog.tsx"
```

---

## Implementation Strategy

### MVP First (US1+US2+US3 Only)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T014) — DB + models + local storage
3. Complete Phase 3: US1+US2 (T015-T019) — scan in/out
4. Complete Phase 4: US3 (T020-T022) — active session display + auto-close
5. **STOP and VALIDATE**: Test full cleaning loop on device with real QR codes
6. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. US1+US2 → Scan in/out works → **First testable increment**
3. US3 → Active session visible on main screen → **MVP complete**
4. US4 → Shift cleaning history → Employee self-management
5. US5 → Dashboard overview → Supervisor visibility
6. US6 → Analytics → Performance insights

### Parallel Team Strategy

With two developers (Flutter + Dashboard):

1. Both complete Setup + Foundational together
2. **Flutter dev**: Phase 3 → 4 → 5 → 8 (US1+US2 → US3 → US4 → Polish)
3. **Dashboard dev**: Phase 6 → 7 (US5 → US6)
4. Stories complete and integrate independently via shared Supabase backend

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- The Supabase migration (T005-T009) is split into logical parts but produces ONE file: `016_cleaning_qr_tracking.sql`
- QR code test data: Use IDs like "8FJ3K2L9H4" (Studio 201, Le Citadin) — see quickstart.md
- Phase 6 (Dashboard) is fully parallelizable with Flutter phases since they share only the Supabase backend
