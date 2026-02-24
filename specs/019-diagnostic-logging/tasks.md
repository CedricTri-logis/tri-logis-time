# Tasks: Diagnostic Logging

**Input**: Design documents from `/specs/019-diagnostic-logging/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in spec. Tests omitted.

**Organization**: Tasks grouped by user story. US2 (Logger Service) and US5 (Sync to Server) form the foundational infrastructure. US1/US3 (GPS Diagnostic Events) is the MVP. US4 (Shift & Sync Events) follows.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story (US1-US5) from spec.md

---

## Phase 1: Setup

**Purpose**: Database migration — no new Flutter dependencies required

- [x] T001 Create Supabase migration `supabase/migrations/036_diagnostic_logs.sql` — create `diagnostic_logs` table with columns (id UUID PK, employee_id, shift_id, device_id, event_category, severity, message, metadata JSONB, app_version, platform, os_version, created_at TIMESTAMPTZ, received_at TIMESTAMPTZ DEFAULT NOW()), indexes (employee+created_at, shift_id, category+severity, created_at DESC), RLS policies (INSERT for own employee_id, SELECT for admin/manager), `sync_diagnostic_logs(p_events JSONB)` RPC per contracts/sync_diagnostic_logs.md, and pg_cron retention job (DELETE WHERE created_at < NOW() - INTERVAL '90 days', daily at 3am). See data-model.md and contracts/sync_diagnostic_logs.md for full schema and SQL.

**Checkpoint**: Migration applied, `diagnostic_logs` table and `sync_diagnostic_logs` RPC exist in Supabase

---

## Phase 2: Foundation — Logger Infrastructure (US2 + US5)

**Purpose**: Core DiagnosticLogger service + local storage + server sync. MUST complete before any user story instrumentation.

**⚠️ CRITICAL**: No debugPrint replacement can begin until this phase is complete.

- [ ] T002 Add `diagnostic_events` table to local SQLCipher database in `gps_tracker/lib/shared/services/local_database.dart` — bump schema version to 4, add CREATE TABLE with columns matching data-model.md (id TEXT PK, employee_id, shift_id, device_id, event_category, severity, message, metadata TEXT/JSON, app_version, platform, os_version, sync_status DEFAULT 'pending', created_at), add CHECK constraints for event_category, severity, sync_status, add indexes (sync_status, created_at, category+severity), add v3→v4 migration in `_onUpgrade`. Add methods: `insertDiagnosticEvent(DiagnosticEvent)`, `getPendingDiagnosticEvents({int limit = 200})` returning events WHERE sync_status='pending' AND severity != 'debug' ORDER BY created_at ASC, `markDiagnosticEventsSynced(List<String> ids)`, `pruneDiagnosticEvents({int maxCount = 5000})` deleting oldest WHERE sync_status='synced', `getDiagnosticEventCount()`.

- [ ] T003 Create DiagnosticEvent model in `gps_tracker/lib/shared/models/diagnostic_event.dart` — define `EventCategory` enum (gps, shift, sync, auth, permission, lifecycle, thermal, error, network), `Severity` enum (debug, info, warn, error, critical), and `DiagnosticEvent` class with all fields from data-model.md (id, employee_id, shift_id, device_id, event_category, severity, message, metadata Map<String,dynamic>?, app_version, platform, os_version, sync_status, created_at). Include `toMap()`/`fromMap()` for SQLite, `toJson()` for RPC serialization (converts to format expected by sync_diagnostic_logs RPC). Generate UUID in factory constructor.

- [ ] T004 Create DiagnosticLogger service in `gps_tracker/lib/shared/services/diagnostic_logger.dart` — singleton pattern initialized at app startup with LocalDatabase, employeeId, deviceId. Auto-detect app_version via PackageInfo, platform via Platform.isIOS/isAndroid, os_version via device_info_plus. Provide `log({required EventCategory category, required Severity severity, required String message, String? shiftId, Map<String,dynamic>? metadata})` method that: (1) creates DiagnosticEvent with all context fields, (2) async fire-and-forget inserts into local DB (try-catch, never throws), (3) in debug mode also calls `debugPrint('[Diag:$category:$severity] $message')`. Provide convenience methods: `gps(...)`, `shift(...)`, `sync(...)`, `auth(...)`, `thermal(...)`, `lifecycle(...)`, `network(...)`, `permission(...)`. Provide `setShiftId(String?)` to update active shift context. Provide `setEmployeeId(String?)` for auth state changes. See quickstart.md for usage examples.

- [ ] T005 Create DiagnosticSyncService in `gps_tracker/lib/features/shifts/services/diagnostic_sync_service.dart` — takes LocalDatabase and Supabase client. Provide `syncDiagnosticEvents()` method that: (1) queries pending non-debug events via `getPendingDiagnosticEvents(limit: 200)`, (2) if none, returns early, (3) maps events to JSON array via `toJson()`, (4) calls `sync_diagnostic_logs` RPC with p_events, (5) on success: marks all event IDs as synced via `markDiagnosticEventsSynced()`, (6) on error: logs to debugPrint and returns (events stay pending for next cycle), (7) calls `pruneDiagnosticEvents()` after sync to enforce 5000 limit. Process multiple batches if >200 pending. Return sync count for SyncService progress reporting.

- [ ] T006 Integrate DiagnosticSyncService into existing sync cycle in `gps_tracker/lib/features/shifts/services/sync_service.dart` — add DiagnosticSyncService as dependency (injected or created internally). In `syncAll()` method, add step 5 AFTER trip detection (lowest priority): call `_syncDiagnosticEvents()`. Wrap in try-catch so diagnostic sync failures never affect GPS point or shift sync. Report diagnostic sync count in SyncProgress stream.

- [ ] T007 Add `diagnostic` message type handler in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — in the `_onTaskData()` message handler switch, add case for `'diagnostic'` message type. When received, extract category, severity, message, metadata from the JSON payload and forward to `DiagnosticLogger.log()`. This enables the background isolate (GPSTrackingHandler) to log diagnostics via the existing message channel.

- [ ] T008 Create Riverpod provider for DiagnosticLogger in `gps_tracker/lib/shared/providers/diagnostic_provider.dart` — create `diagnosticLoggerProvider` that initializes DiagnosticLogger singleton with LocalDatabase, current user ID from auth state, and device ID from DeviceIdService. Ensure it updates employeeId when auth state changes. Make it accessible throughout the widget tree.

- [ ] T009 Initialize DiagnosticLogger at app startup in `gps_tracker/lib/main.dart` — after Supabase + LocalDatabase initialization succeeds, initialize DiagnosticLogger with device context. Log `app_started` event with metadata: `{init_duration_ms, app_version, platform, os_version, device_model}`. If initialization fails, log `app_startup_failed` event with `{error_message, failed_service}` (if logger was already partially initialized). Note: logger init must NOT block app startup — wrap in try-catch.

**Checkpoint**: DiagnosticLogger can log events locally, sync them to server via existing sync cycle, and handle background isolate messages. Ready for instrumentation.

---

## Phase 3: US1 + US3 — GPS Tracking Diagnostic Events (P1) 🎯 MVP

**Goal**: Replace all GPS-related debugPrint calls with structured DiagnosticLogger events. After this phase, all GPS tracking failures are visible on the server.

**Independent Test**: Clock in on a device, wait for GPS tracking to start. Simulate GPS loss (airplane mode briefly). Verify `tracking_started`, `gps_lost`, `gps_restored` events appear in Supabase `diagnostic_logs` table.

### Implementation

- [ ] T010 [US3] Instrument `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — replace ALL debugPrint calls with DiagnosticLogger. Specific mappings from research.md: (1) `_refreshServiceState` point count error → `logger.gps(severity: error, message: 'Failed to load point count from DB', metadata: {error})`, (2) service running restart → `logger.lifecycle(info, 'Service was running, restarting state')`, (3) stream recovered → `logger.gps(info, 'Stream recovered', {attempt_number, gap_duration_seconds})`, (4) stream recovery struggling → `logger.gps(warn, 'Stream recovery failing', {attempt_count, gap_minutes})`, (5) GPS lost → `logger.gps(warn, 'GPS signal lost', {gap_started_at, last_position, seconds_since_last})`, (6) GPS restored → `logger.gps(info, 'GPS signal restored', {gap_duration_seconds, recovery_method})`, (7) GPS gap insert error → `logger.gps(error, 'Failed to record GPS gap', {error})`, (8) GPS point insert error → `logger.gps(error, 'Failed to insert GPS point', {error, shift_id})`, (9) heartbeat failed → `logger.sync(warn, 'Server heartbeat failed', {error})`, (10) consecutive heartbeat failures → `logger.sync(error, 'Heartbeat escalation', {failure_count, seconds_since_last_success})`, (11) shift completed on server → `logger.shift(info, 'Shift closed by server', {shift_id, reason, source})`, (12) GPS gap self-healing → `logger.gps(info, 'GPS gap self-healing triggered', {gap_seconds})`, (13) midnight warning → `logger.shift(info, 'Midnight warning shown', {shift_id})`, (14) post-midnight validation → `logger.shift(info, 'Midnight closure check', {shift_id})`, (15) FGS died → `logger.gps(error, 'Foreground service died', {detected_at})`, (16) FGS restarted → `logger.gps(info, 'Foreground service restarted', {restart_reason})`, (17) significant location change → `logger.gps(info, 'Significant location wakeup', {latitude, longitude, accuracy})`, (18) iOS relaunch validation → `logger.gps(info, 'iOS relaunch shift validation', {result})`, (19) thermal stream error → `logger.thermal(warn, 'Thermal stream error', {error})`, (20) thermal adaptation → `logger.thermal(info, 'Thermal adaptation applied', {level, active_interval, stationary_interval})`, (21) service dead but shift active → `logger.gps(error, 'Service dead but shift active', {shift_id})`. Also add tracking_started and tracking_stopped events in startTracking()/stopTracking() methods.

- [ ] T011 [P] [US3] Instrument `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` — replace 2 debugPrint calls: (1) foreground service died → `logger.gps(error, 'Foreground service died — notifying for restart')`, (2) failed to check service health → `logger.gps(error, 'Failed to check foreground service health', {error})`. Note: this file runs in main isolate so can use DiagnosticLogger directly.

- [ ] T012 [P] [US3] Instrument `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart` — this runs in background isolate, so CANNOT use DiagnosticLogger directly. Instead, send `diagnostic` messages via `FlutterForegroundTask.sendDataToMain(jsonEncode({...}))`. Add diagnostic messages for: (1) onStart success → `{type: 'diagnostic', category: 'gps', severity: 'info', message: 'GPS handler started', metadata: {shift_id, platform_settings}}`, (2) initial position timeout → `{..., severity: 'warn', message: 'Initial position capture timeout'}`, (3) position stream error → `{..., severity: 'warn', message: 'Position stream error', metadata: {error}}`, (4) stream recovery attempt → `{..., severity: 'info', message: 'Stream recovery attempt', metadata: {attempt_number, backoff_minutes}}`, (5) GPS loss detected → already sent as 'gps_lost' message (handled in T010), (6) force capture fallback → `{..., severity: 'debug', message: 'Force capture for stationary', metadata: {stationary_duration_seconds}}`.

- [ ] T013 [P] [US3] Instrument `gps_tracker/lib/features/tracking/services/significant_location_service.dart` — replace 3 debugPrint calls: (1) monitoring started → `logger.gps(info, 'Significant location monitoring started')`, (2) monitoring stopped → `logger.gps(info, 'Significant location monitoring stopped')`, (3) woken by location change → `logger.gps(info, 'Woken by significant location change', {latitude, longitude, accuracy})`. Also add error cases for start/stop failures.

- [ ] T014 [P] [US3] Instrument `gps_tracker/lib/features/tracking/services/background_execution_service.dart` — replace 6 debugPrint calls: (1) session started → `logger.lifecycle(debug, 'Background session started')`, (2) session stopped → `logger.lifecycle(debug, 'Background session stopped')`, (3) session check error → `logger.lifecycle(warn, 'Background session check error', {error})`, (4) task started → `logger.lifecycle(debug, 'Background task started')`, (5) task ended → `logger.lifecycle(debug, 'Background task ended')`, (6) task error → `logger.lifecycle(warn, 'Background task error', {error})`, (7) task expired → `logger.lifecycle(warn, 'Background task expired')`.

- [ ] T015 [P] [US3] Instrument `gps_tracker/lib/features/tracking/services/thermal_state_service.dart` — replace 2 debugPrint calls: (1) current level error → `logger.thermal(warn, 'Failed to read thermal level', {error})`, (2) Android stream error → `logger.thermal(warn, 'Thermal stream error', {error})`. Add thermal level changed event when stream delivers new value.

- [ ] T016 [P] [US3] Add `force_logout` diagnostic event in `gps_tracker/lib/features/auth/providers/device_session_provider.dart` — in `_handleForceLogout()`, log `logger.auth(critical, 'Force logout triggered', {source: 'realtime'|'polling'})`. This is P1 because force-logout directly affects GPS tracking.

**Checkpoint**: All GPS tracking, background service, thermal, and critical auth events are instrumented. Clocking in and experiencing GPS issues produces structured diagnostic events synced to server. **This is the MVP — stop and validate here.**

---

## Phase 4: US4 — Shift & Sync Diagnostic Events (P2)

**Goal**: Replace remaining debugPrint calls in shift, sync, network, and mileage services.

**Independent Test**: Perform clock-in/out with intermittent connectivity. Verify `clock_in_success`, `sync_completed`, `connectivity_changed` events appear in `diagnostic_logs`.

### Implementation

- [ ] T017 [P] [US4] Instrument `gps_tracker/lib/features/shifts/providers/shift_provider.dart` — replace 1 debugPrint (server closed shift → `logger.shift(warn, 'Shift closed by server', {shift_id, reason, source})`). Add new events: clock_in_attempt, clock_in_success, clock_in_failure, clock_out_attempt, clock_out_success, clock_out_failure in the clockIn()/clockOut() methods with metadata per data-model.md shift events table.

- [ ] T018 [P] [US4] Instrument `gps_tracker/lib/features/shifts/services/sync_service.dart` — replace 6 debugPrint calls: (1) quarantined orphaned GPS point → `logger.sync(warn, 'Record quarantined', {type: 'gps_point', record_id, reason: 'orphaned_shift', attempt_count})`, (2) GPS gaps sync result → `logger.sync(info, 'GPS gaps synced', {count})`, (3) GPS gaps sync failed → `logger.sync(error, 'GPS gaps sync failed', {error})`, (4) mileage trip re-detection completed → `logger.sync(debug, 'Trip re-detection completed', {shift_id})`, (5) mileage trip re-detection failed → `logger.sync(warn, 'Trip re-detection failed', {shift_id, error})`, (6) mileage trigger error → `logger.sync(error, 'Trip re-detection trigger error', {error})`. Add sync_started and sync_completed events in syncAll() with metadata per data-model.md sync events table.

- [ ] T019 [P] [US4] Instrument `gps_tracker/lib/shared/services/realtime_service.dart` — replace 4 debugPrint calls: (1) session change detected → `logger.network(info, 'Device session change detected')`, (2) session channel status → `logger.network(debug, 'Realtime session channel status', {status, error})`, (3) shift change detected → `logger.network(info, 'Shift change detected via Realtime')`, (4) shift channel status → `logger.network(debug, 'Realtime shift channel status', {status, error})`.

- [ ] T020 [P] [US4] Instrument `gps_tracker/lib/features/mileage/services/trip_service.dart` — replace 6 debugPrint calls with `logger.sync(...)` calls: trip detection failed/completed (debug/warn), classification update failed (warn). Use category `sync` since these are server-side operations.

- [ ] T021 [P] [US4] Instrument `gps_tracker/lib/features/shifts/services/version_check_service.dart` — replace 1 debugPrint: version check failed → `logger.lifecycle(warn, 'Version check failed', {error})`.

- [ ] T022 [US4] Add `db_recovery` diagnostic event in `gps_tracker/lib/shared/services/local_database.dart` — in `_recoverFromCorruptKeystore()`, after recovery completes and fresh DB is created, log `logger.lifecycle(critical, 'Database recovery from BAD_DECRYPT', {reason: 'bad_decrypt', action: 'wipe_and_recreate'})`. Note: logger may need re-initialization after DB wipe — handle gracefully.

**Checkpoint**: All remaining debugPrint calls replaced. Full diagnostic coverage across GPS, shift, sync, auth, network, thermal, lifecycle, and permission events.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Verification, cleanup, and edge case handling

- [ ] T023 Verify all debugPrint calls migrated by searching codebase for remaining `debugPrint(` calls in instrumented files (tracking_provider, background_tracking_service, gps_tracking_handler, significant_location_service, background_execution_service, thermal_state_service, sync_service, shift_provider, device_session_provider, realtime_service, trip_service, version_check_service, main.dart). Any remaining non-diagnostic debugPrints should be intentional and documented.

- [ ] T024 Run `flutter analyze` in `gps_tracker/` to verify no lint errors or type issues from the DiagnosticLogger integration.

- [ ] T025 Verify local storage pruning works correctly — ensure `pruneDiagnosticEvents()` is called after each sync cycle in DiagnosticSyncService and correctly deletes oldest synced events when count exceeds 5000. Verify the count query and delete query work with the actual SQLCipher schema.

- [ ] T026 Add `connectivity_changed` diagnostic event — if not already covered by SyncService instrumentation, ensure the existing ConnectivityService stream triggers a `logger.network(info, 'Connectivity changed', {new_type, previous_type, offline_duration_seconds})` event. This may require adding DiagnosticLogger to the SyncProvider or ConnectivityService consumer.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundation (Phase 2)**: Depends on Phase 1 (needs `diagnostic_events` table referenced in local_database.dart changes, which are developed alongside the migration)
- **US1+US3 GPS Events (Phase 3)**: Depends on Phase 2 (needs DiagnosticLogger and sync infrastructure)
- **US4 Shift & Sync Events (Phase 4)**: Depends on Phase 2 (needs DiagnosticLogger). Independent of Phase 3.
- **Polish (Phase 5)**: Depends on Phases 3 and 4

### User Story Dependencies

- **US2 (Logger Service)** + **US5 (Sync to Server)**: Combined in Phase 2 as foundational infrastructure
- **US1 (Server-Side Collection)**: Satisfied when US2 + US3 + US5 are complete (verified in Phase 3 checkpoint)
- **US3 (GPS Events)**: Depends only on Phase 2 — can start immediately after foundation
- **US4 (Shift & Sync Events)**: Depends only on Phase 2 — can run in parallel with Phase 3

### Within Each Phase

- T002 (local DB) and T003 (model) can run in parallel
- T004 (logger) depends on T002 + T003
- T005 (sync service) depends on T002 + T003
- T006 (sync integration) depends on T005
- T007 (message handler) depends on T004
- T008 (provider) depends on T004
- T009 (app startup) depends on T004 + T008
- Phase 3 tasks T010-T016 all depend on T004 but are parallelizable with each other ([P] marked)
- Phase 4 tasks T017-T022 all depend on T004 but are parallelizable with each other ([P] marked)

### Parallel Opportunities

**Phase 2 parallel group 1:**
```
T002 (local DB schema) || T003 (DiagnosticEvent model)
```

**Phase 2 parallel group 2 (after group 1):**
```
T004 (DiagnosticLogger) || T005 (DiagnosticSyncService)
```

**Phase 3 parallel (all GPS instrumentation, after T007):**
```
T010 (tracking_provider) || T011 (background_tracking_service) || T012 (gps_tracking_handler) || T013 (significant_location_service) || T014 (background_execution_service) || T015 (thermal_state_service) || T016 (device_session_provider)
```

**Phase 4 parallel (all shift/sync instrumentation, after Phase 2):**
```
T017 (shift_provider) || T018 (sync_service) || T019 (realtime_service) || T020 (trip_service) || T021 (version_check_service) || T022 (local_database)
```

---

## Implementation Strategy

### MVP First (Phase 1 + 2 + 3)

1. Complete Phase 1: Apply migration 036
2. Complete Phase 2: Build DiagnosticLogger + local DB + sync service
3. Complete Phase 3: Instrument all GPS tracking code
4. **STOP and VALIDATE**: Clock in, simulate GPS loss, verify events on server
5. Deploy to TestFlight/Play Store — GPS diagnostics immediately useful

### Full Delivery (Add Phase 4 + 5)

6. Complete Phase 4: Instrument remaining shift/sync/network code
7. Complete Phase 5: Verify completeness, cleanup
8. Deploy final version with full diagnostic coverage

### Key Decision: Phase 3 is the MVP

Phase 3 alone covers all GPS-related diagnostics (the primary motivation for this feature). Phases 4-5 add completeness but Phase 3 delivers the core value: **remote visibility into GPS tracking failures**.
