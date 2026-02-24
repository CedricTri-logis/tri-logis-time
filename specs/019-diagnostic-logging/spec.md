# Feature Specification: Diagnostic Logging

**Feature Branch**: `019-diagnostic-logging`
**Created**: 2026-02-24
**Status**: Draft
**Input**: User description: "Comprehensive diagnostic logging system to detect GPS tracking failures. All logs must be sent to the server, not just stored locally on the phone."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Server-Side Diagnostic Log Collection (Priority: P1)

As an administrator, I want all critical app events (GPS tracking, shifts, errors, recovery attempts) to be automatically sent to the server so I can diagnose issues remotely without needing physical access to the employee's device.

**Why this priority**: The core problem is that currently all diagnostic information (36+ debugPrint statements, GPS loss/recovery events, sync failures, heartbeat failures, etc.) exists only in the device console — completely invisible in production. This is the highest priority because without server-side visibility, GPS failures are undetectable.

**Independent Test**: Can be fully tested by clocking in on a device, simulating GPS loss, and verifying that diagnostic events appear in the Supabase `diagnostic_logs` table within seconds.

**Acceptance Scenarios**:

1. **Given** an employee clocks in and GPS tracking starts, **When** the GPS stream delivers positions normally, **Then** key lifecycle events (tracking_started, position_captured summary, heartbeat) are logged to the server.
2. **Given** GPS signal is lost for 90+ seconds, **When** the handler detects signal loss, **Then** a `gps_lost` diagnostic event with gap start time, last known position, and device state is sent to the server.
3. **Given** GPS signal is restored after a gap, **When** the handler detects restoration, **Then** a `gps_restored` event with gap duration and recovery method is sent to the server.
4. **Given** the GPS stream recovery mechanism fires (exponential backoff), **When** each recovery attempt occurs, **Then** a `stream_recovery_attempt` event with attempt number and backoff interval is sent to the server.
5. **Given** the device is offline, **When** diagnostic events are generated, **Then** events are persisted locally in SQLCipher and batch-synced when connectivity returns.

---

### User Story 2 - Centralized Diagnostic Logger Service (Priority: P1)

As a developer, I want a single `DiagnosticLogger` service that replaces all scattered `debugPrint` calls so that every significant event is captured consistently with structured metadata (timestamp, device ID, shift ID, employee ID, event category, severity).

**Why this priority**: This is equally P1 because it's the foundation that US1 depends on. Without a centralized service, we can't reliably collect and send logs.

**Independent Test**: Can be tested by instrumenting one service (e.g., TrackingProvider) and verifying structured log entries appear in local DB with all required metadata fields populated.

**Acceptance Scenarios**:

1. **Given** any existing `debugPrint('[Tracking] ...')` call site, **When** replaced with `DiagnosticLogger.log()`, **Then** the event is persisted locally with category, severity, message, and structured metadata JSON.
2. **Given** the logger is called from the background isolate (GPSTrackingHandler), **When** a position error occurs, **Then** the event is sent to the main isolate via the existing message channel and logged from there.
3. **Given** the app starts up, **When** initialization succeeds or fails, **Then** an `app_startup` event is logged with initialization duration, success/failure status, and error details if any.

---

### User Story 3 - GPS Tracking Diagnostic Events (Priority: P1)

As an administrator, I want detailed GPS-specific diagnostic events so I can understand exactly why an employee's GPS tracking failed, including: signal loss frequency, recovery success rate, thermal throttling, foreground service deaths, iOS significant location activations, and permission changes.

**Why this priority**: GPS reliability is the entire motivation for this feature. The specific GPS events are what make the logs actionable.

**Independent Test**: Can be tested by running the app through various GPS scenarios (signal loss, thermal throttle, app backgrounding) and verifying each produces a distinct, descriptive diagnostic event.

**Acceptance Scenarios**:

1. **Given** the thermal state changes to elevated or critical, **When** GPS intervals are adapted, **Then** a `thermal_adaptation` event is logged with old/new intervals and thermal level.
2. **Given** the foreground service dies on Android, **When** detected on app resume, **Then** a `foreground_service_died` event is logged with time since last known alive.
3. **Given** iOS Significant Location Change fires, **When** the app is woken, **Then** a `significant_location_wakeup` event is logged with the wakeup location and reason.
4. **Given** the server heartbeat fails 10 consecutive times, **When** escalation triggers, **Then** a `heartbeat_escalation` event is logged with failure count and duration since last success.
5. **Given** location permission changes from "always" to "while in use", **When** the permission monitor detects the change, **Then** a `permission_changed` event is logged with old and new permission levels.

---

### User Story 4 - Shift & Sync Diagnostic Events (Priority: P2)

As an administrator, I want shift lifecycle and sync diagnostic events so I can track clock-in/out success rates, sync failures, quarantined records, and connectivity patterns per device.

**Why this priority**: Important for overall system health but secondary to GPS-specific diagnostics.

**Independent Test**: Can be tested by performing clock-in/out operations with intermittent connectivity and verifying sync events appear on server.

**Acceptance Scenarios**:

1. **Given** a clock-in attempt, **When** it succeeds or fails, **Then** a `clock_in` event is logged with result, duration, server response, and location accuracy.
2. **Given** GPS points are synced, **When** the batch completes, **Then** a `sync_batch` event is logged with synced/failed/duplicate counts and duration.
3. **Given** a GPS point is quarantined as orphaned, **When** the quarantine occurs, **Then** a `record_quarantined` event is logged with the orphan reason and attempt count.
4. **Given** connectivity changes, **When** going online/offline, **Then** a `connectivity_change` event is logged with network type and duration of previous state.

---

### User Story 5 - Diagnostic Log Sync to Server (Priority: P1)

As a system, diagnostic logs must be reliably synced to the server without impacting GPS tracking performance or battery life.

**Why this priority**: P1 because the entire feature is useless if logs don't reach the server reliably.

**Independent Test**: Can be tested by generating 100+ diagnostic events while offline, restoring connectivity, and verifying all events arrive on the server within one sync cycle.

**Acceptance Scenarios**:

1. **Given** the device is online, **When** a high-severity diagnostic event occurs (error, gps_lost), **Then** it is synced to the server within 60 seconds (piggybacks on existing sync cycle).
2. **Given** the device is offline, **When** diagnostic events accumulate, **Then** they are stored locally (max 5000 entries) and batch-synced when connectivity returns.
3. **Given** diagnostic log sync fails, **When** the next sync cycle runs, **Then** previously unsent logs are retried without duplicates (using client-side event IDs).
4. **Given** the diagnostic log table exceeds 5000 local entries, **When** new events arrive, **Then** the oldest synced entries are pruned to maintain storage limits.

---

### Edge Cases

- What happens when the background isolate generates logs but can't communicate with the main isolate? → Events are sent via the existing FlutterForegroundTask message channel as structured JSON.
- What happens if diagnostic log sync itself fails repeatedly? → Logs are kept locally; sync failures don't affect GPS point sync (separate sync path).
- What happens if the device clock is significantly wrong? → Use `DateTime.now().toUtc()` consistently; server records `received_at` for comparison.
- What happens during BAD_DECRYPT recovery (full DB wipe)? → Unsent logs are lost, but a `db_recovery` event is generated on the fresh database.
- What happens if logging overhead impacts GPS capture timing? → Logging is async (fire-and-forget local insert); sync is batched and throttled.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a centralized `DiagnosticLogger` service accessible from all Dart code (main isolate and via message passing from background isolate).
- **FR-002**: System MUST persist all diagnostic events locally in an encrypted SQLCipher table (`diagnostic_events`) before attempting server sync.
- **FR-003**: System MUST sync diagnostic events to a new Supabase `diagnostic_logs` table via a dedicated RPC (`sync_diagnostic_logs`).
- **FR-004**: System MUST replace all existing `debugPrint('[Tracking]...')`, `debugPrint('[BackgroundTracking]...')`, `debugPrint('[SyncService]...')`, `debugPrint('[SignificantLocation]...')`, `debugPrint('[BackgroundExecution]...')`, `debugPrint('[ThermalState]...')`, `debugPrint('[Main]...')`, and `debugPrint('[Mileage]...')` calls with structured `DiagnosticLogger` calls.
- **FR-005**: System MUST include structured metadata with every event: `event_category`, `severity`, `shift_id`, `employee_id`, `device_id`, `app_version`, `platform` (ios/android), `message`, and optional `metadata` JSON.
- **FR-006**: System MUST support event categories: `gps`, `shift`, `sync`, `auth`, `permission`, `lifecycle`, `thermal`, `error`, `network`.
- **FR-007**: System MUST support severity levels: `debug`, `info`, `warn`, `error`, `critical`.
- **FR-008**: System MUST NOT sync `debug`-level events to the server (local only) to conserve bandwidth and storage.
- **FR-009**: System MUST batch diagnostic events during sync (max 200 per RPC call) to avoid oversized payloads.
- **FR-010**: System MUST maintain local storage limit of 5000 diagnostic events, pruning oldest synced events when exceeded.
- **FR-011**: System MUST use idempotent sync via client-side event UUIDs to prevent duplicate server entries.
- **FR-012**: Diagnostic log sync MUST NOT block or delay GPS point sync — it runs as a separate, lower-priority sync path.
- **FR-013**: System MUST continue to output to `debugPrint` in debug mode for developer console visibility.
- **FR-014**: System MUST log a `session_start` event on app launch with device info, app version, platform, and OS version.
- **FR-015**: System MUST log all GPS lifecycle events: `tracking_started`, `tracking_stopped`, `gps_lost`, `gps_restored`, `stream_recovery_attempt`, `stream_recovered`, `foreground_service_died`, `foreground_service_restarted`, `significant_location_wakeup`, `thermal_adaptation`, `position_error`.
- **FR-016**: System MUST log shift events: `clock_in_attempt`, `clock_in_success`, `clock_in_failure`, `clock_out_attempt`, `clock_out_success`, `clock_out_failure`, `shift_closed_by_server`, `midnight_warning`, `midnight_closure`.
- **FR-017**: System MUST log sync events: `sync_started`, `sync_completed`, `sync_failed`, `batch_synced`, `record_quarantined`, `connectivity_changed`.
- **FR-018**: System MUST log auth events: `sign_in`, `sign_out`, `force_logout`, `session_restored`, `biometric_auth`.
- **FR-019**: System MUST log permission events: `permission_changed`, `permission_denied`, `battery_optimization_status`.

### Key Entities

- **DiagnosticEvent**: A single logged event with id (UUID), event_category, severity, message, metadata (JSON), shift_id, employee_id, device_id, app_version, platform, os_version, created_at, sync_status.
- **diagnostic_logs (Supabase)**: Server-side table receiving synced events, with additional `received_at` timestamp and RLS for admin-only reads.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of GPS loss/restore events are captured and visible on the server within 5 minutes of the device regaining connectivity.
- **SC-002**: Zero increase in battery consumption from diagnostic logging (async, batched, piggybacks on existing sync).
- **SC-003**: Diagnostic events include sufficient metadata to reconstruct a complete GPS tracking timeline for any shift (start, positions, gaps, recoveries, stop).
- **SC-004**: Local diagnostic storage never exceeds 2MB (5000 events × ~400 bytes average).
- **SC-005**: Diagnostic log sync adds less than 2 seconds to the existing sync cycle.
- **SC-006**: All 36+ existing debugPrint call sites are migrated to structured DiagnosticLogger calls.
