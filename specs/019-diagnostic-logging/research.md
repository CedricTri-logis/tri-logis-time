# Research: 019-diagnostic-logging

**Date**: 2026-02-24
**Status**: Complete

## Research Task 1: Current Logging Infrastructure

### Decision: Extend existing SyncLogger pattern + new DiagnosticLogger service

### Rationale
The codebase already has a `SyncLogger` service (`features/shifts/services/sync_logger.dart`) that persists structured logs to a local `sync_log_entries` SQLite table. However, this logger:
- Only covers sync operations (not GPS, auth, lifecycle, etc.)
- Never syncs to the server
- Has a 10,000 entry rotation limit
- Uses a different schema than what we need (no device_id, shift_id, category)

Rather than extending SyncLogger, we create a new `DiagnosticLogger` that:
1. Covers all event categories (gps, shift, sync, auth, permission, lifecycle, thermal, error, network)
2. Includes rich structured metadata (device_id, shift_id, app_version, platform)
3. Syncs to server via dedicated RPC
4. Coexists with SyncLogger (which remains for detailed sync debugging)

### Alternatives Considered
1. **Extend SyncLogger**: Rejected — SyncLogger is tightly coupled to sync operations, has no server sync, and would require breaking changes to the existing schema.
2. **Third-party logging (Sentry/Crashlytics)**: Rejected — Adds external dependency, costs money at scale, and doesn't integrate with existing Supabase infrastructure.
3. **Supabase Edge Functions for log ingestion**: Rejected — Unnecessary complexity; a simple RPC with batch insert is sufficient and consistent with existing sync patterns (sync_gps_points).

---

## Research Task 2: Background Isolate Logging Strategy

### Decision: Use existing FlutterForegroundTask message channel

### Rationale
The `GPSTrackingHandler` runs in a background isolate and already communicates with the main isolate via `FlutterForegroundTask.sendDataToMain()`. Current message types include: `position`, `error`, `heartbeat`, `started`, `stopped`, `status`, `gps_lost`, `gps_restored`, `stream_recovered`, `stream_recovery_failing`.

For diagnostic logging from the background isolate:
- Add a new message type `diagnostic` that carries structured event data
- The `TrackingNotifier` in the main isolate receives these messages and forwards to `DiagnosticLogger`
- This avoids any cross-isolate database access issues (SQLCipher handle is main isolate only)

### Alternatives Considered
1. **Direct DB access from background isolate**: Rejected — SQLCipher connections are not thread-safe across isolates; would require a separate DB connection with potential lock contention.
2. **File-based logging from background isolate**: Rejected — Adds complexity, requires file synchronization, and doesn't integrate with the existing message channel pattern.
3. **SendPort/ReceivePort dedicated channel**: Rejected — FlutterForegroundTask already manages the communication channel; adding another introduces unnecessary complexity.

---

## Research Task 3: Server-Side Storage & RPC Design

### Decision: New `diagnostic_logs` table + `sync_diagnostic_logs` RPC (migration 036)

### Rationale
Following the established pattern of `sync_gps_points` RPC (migration 027):
- Batch insert via RPC (not direct table insert) for atomicity and deduplication
- Client sends array of events with client-side UUIDs
- Server handles `unique_violation` gracefully (counts as duplicate, not error)
- RLS: employees can INSERT their own logs, admins can SELECT all logs
- Automatic `received_at` timestamp on server for clock drift detection

The table should be:
- Partitioned by `created_at` month for efficient queries and cleanup
- Indexed on `employee_id`, `shift_id`, `event_category`, `severity`
- Retention: 90 days (server-side cleanup via pg_cron)

### Alternatives Considered
1. **Supabase Storage (file-based logs)**: Rejected — Not queryable, no real-time visibility, harder to aggregate across devices.
2. **Separate logging database**: Rejected — Over-engineering; diagnostic logs fit naturally in the existing Supabase instance.
3. **Direct table inserts (no RPC)**: Rejected — RPCs allow batch deduplication, atomic processing, and server-side validation, consistent with sync_gps_points pattern.

---

## Research Task 4: Battery & Performance Impact

### Decision: Async fire-and-forget local inserts + piggyback on existing sync cycle

### Rationale
Key performance constraints:
1. **Local insert**: ~0.1ms per SQLite insert (negligible). Fire-and-forget pattern (errors caught, never thrown).
2. **Server sync**: Piggyback on existing SyncService cycle (runs on connectivity change + periodic). Diagnostic logs sync AFTER GPS points (lower priority).
3. **Batch size**: 200 events per RPC call (smaller payloads than GPS points which do 100 points with more data per point).
4. **Debug filtering**: `debug`-level events are local-only, never synced. This eliminates ~60% of log volume.
5. **No additional wake-ups**: No new timers, no new background tasks. Diagnostic sync hooks into existing sync infrastructure.

Expected overhead:
- Storage: ~400 bytes per event × 5000 max = 2MB worst case
- Network: ~200 events × 400 bytes = 80KB per sync batch (negligible on cellular)
- CPU: Async inserts with no blocking; JSON serialization is trivial

### Alternatives Considered
1. **Separate sync timer for diagnostics**: Rejected — Additional wake-ups increase battery drain. Piggyback approach is zero-cost.
2. **Real-time streaming via Supabase Realtime**: Rejected — Unnecessary complexity and bandwidth; batch sync is sufficient for diagnostics.
3. **Sampling (log only every Nth event)**: Rejected — GPS issues are intermittent; sampling would miss critical events.

---

## Research Task 5: Existing debugPrint Call Sites Inventory

### Decision: Replace all 36+ debugPrint calls across 12 files

### Findings - Complete inventory of call sites to migrate:

#### tracking_provider.dart (17 calls)
- `[Tracking] Failed to load point count from DB` → `error`, `gps` category
- `[Tracking] Service was running, restarting state` → `info`, `lifecycle`
- `[Tracking] Stream recovered after N attempts` → `info`, `gps`
- `[Tracking] Stream recovery struggling: N attempts` → `warn`, `gps`
- `[Tracking] Unknown message type` → `warn`, `lifecycle`
- `[Tracking] GPS lost - activating SLC` → `warn`, `gps`
- `[Tracking] GPS restored - deactivating SLC` → `info`, `gps`
- `[Tracking] Failed to record GPS gap` → `error`, `gps`
- `[Tracking] ERROR inserting GPS point` → `error`, `gps`
- `[Tracking] Server heartbeat failed` → `warn`, `sync`
- `[Tracking] N consecutive heartbeat failures` → `error`, `sync`
- `[Tracking] Shift completed on server` → `info`, `shift`
- `[Tracking] GPS gap self-healing` → `info`, `gps`
- `[Tracking] Midnight warning shown` → `info`, `shift`
- `[Tracking] Post-midnight validation` → `info`, `shift`
- `[Tracking] FGS died - restart` → `error`, `gps`
- `[Tracking] Significant location change` → `info`, `gps`
- `[Tracking] iOS relaunch validation` → `info`, `gps`
- `[Tracking] Thermal stream error` → `warn`, `thermal`
- `[Tracking] Thermal adaptation` → `info`, `thermal`
- `[Tracking] Service dead but shift active` → `error`, `gps`

#### background_tracking_service.dart (2 calls)
- `[BackgroundTracking] Foreground service died` → `error`, `gps`
- `[BackgroundTracking] Failed to check service health` → `error`, `gps`

#### significant_location_service.dart (3 calls)
- `[SignificantLocation] Monitoring started` → `info`, `gps`
- `[SignificantLocation] Monitoring stopped` → `info`, `gps`
- `[SignificantLocation] Woken by location change` → `info`, `gps`

#### background_execution_service.dart (6 calls)
- `[BackgroundExecution] Session started/stopped` → `debug`, `lifecycle`
- `[BackgroundExecution] Task started/ended` → `debug`, `lifecycle`
- `[BackgroundExecution] Task error` → `warn`, `lifecycle`
- `[BackgroundExecution] Background task expired` → `warn`, `lifecycle`

#### thermal_state_service.dart (2 calls)
- `[ThermalState] Current level error` → `warn`, `thermal`
- `[ThermalState] Android stream error` → `warn`, `thermal`

#### sync_service.dart (6 calls)
- `[SyncService] Quarantined orphaned GPS point` → `warn`, `sync`
- `[SyncService] GPS gaps sync result` → `info`, `sync`
- `[SyncService] GPS gaps sync failed` → `error`, `sync`
- `[Mileage] Trip re-detection completed` → `debug`, `sync`
- `[Mileage] Trip re-detection failed` → `warn`, `sync`
- `[Mileage] Failed to trigger trip re-detection` → `error`, `sync`

#### realtime_service.dart (4 calls)
- `RealtimeService: session change detected` → `info`, `network`
- `RealtimeService: session channel status` → `debug`, `network`
- `RealtimeService: shift change detected` → `info`, `network`
- `RealtimeService: shift channel status` → `debug`, `network`

#### main.dart (1 call)
- `[Main] Notification init failed` → `warn`, `lifecycle`

#### shift_provider.dart (1 call)
- `ShiftNotifier: server closed shift` → `info`, `shift`

#### device_session_provider.dart (implicit)
- Force logout detected → `critical`, `auth`

#### version_check_service.dart (1 call)
- `VersionCheckService: failed to check version` → `warn`, `lifecycle`

#### trip_service.dart (6 calls)
- Trip detection failed/completed → `debug`/`warn`, `sync`
- Classification update failed → `warn`, `sync`

---

## Research Task 6: Local Table Schema Design

### Decision: New `diagnostic_events` table in existing SQLCipher database

### Rationale
Consistent with the existing pattern of feature-specific tables in the main encrypted database. The table stores events before sync and marks them as synced after successful server upload.

Schema design considerations:
- UUID primary key (client-generated, used for deduplication on server)
- Separate columns for indexed fields (employee_id, shift_id, category, severity)
- JSON `metadata` column for flexible event-specific data
- `sync_status` for tracking upload state (consistent with local_gps_points pattern)
- `created_at` for ordering and pruning
- No foreign key to local_shifts (events may outlive shift records, and shift_id can be null for non-shift events)

---

## Research Task 7: Migration Numbering & Server Schema

### Decision: Migration 036 for `diagnostic_logs` table + `sync_diagnostic_logs` RPC

### Rationale
- Last migration: 035 (trip_detection_rpc)
- Next available: 036
- Single migration creates both the table and the sync RPC
- Includes pg_cron job for 90-day retention cleanup
- RLS: employees INSERT own logs, admins/managers SELECT all

---

## Research Task 8: Integration with Existing Sync Infrastructure

### Decision: Add diagnostic sync step to existing SyncService.syncAll()

### Rationale
The existing `SyncService.syncAll()` method follows this order:
1. Sync shifts
2. Sync GPS gaps
3. Sync GPS points
4. Trigger trip detection

We add diagnostic log sync as step 5 (lowest priority):
5. Sync diagnostic events

This ensures:
- GPS data always syncs first (highest priority)
- Diagnostic logs never delay critical data
- No additional sync timers or background tasks
- Uses same connectivity detection and error handling patterns
