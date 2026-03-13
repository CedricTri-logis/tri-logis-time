# Exit Reason Collection & Offline-Resilient Diagnostic Upload

**Date:** 2026-03-12
**Status:** Draft
**Branch:** 008-employee-shift-dashboard

## Problem

When the OS kills the GPS Tracker app (memory pressure, battery saver, watchdog, etc.), we currently have no visibility into *why* or *when* the kill happened. We see GPS gaps in the data but cannot distinguish between "OS killed the app" vs "employee turned off location" vs "phone died". This makes debugging tracking failures a guessing game.

## Solution

Automatically collect OS-provided exit reason data on every app launch, store it locally in the existing SQLCipher diagnostic infrastructure, and sync it to Supabase through the existing `DiagnosticSyncService` pipeline. Zero employee intervention required.

## Approach

**Platform Channel dedicated plugin** (`ExitReasonPlugin`) — one native file per platform, one Dart service to consume. Follows the existing pattern of `BackgroundTaskPlugin`, `DiagnosticNativePlugin`, etc.

## Platform APIs

### Android (API 30+ / Android 11+)

**`ApplicationExitInfo`** — per-event exit data with:
- Reason constant (values vary by API level: 14 on API 30, up to 17 on API 34+). Core values: `LOW_MEMORY`, `ANR`, `CRASH`, `CRASH_NATIVE`, `EXCESSIVE_RESOURCE_USAGE`, `USER_REQUESTED`, `USER_STOPPED`, `SIGNALED`, `EXIT_SELF`, `OTHER`, `UNKNOWN`, `INITIALIZATION_FAILURE`, `PERMISSION_CHANGE`, `DEPENDENCY_DIED`. API 31+: `FREEZER`, `PACKAGE_STATE_CHANGE`, `PACKAGE_UPDATED`. Implementation must handle unknown reason codes gracefully (map to `"unknown_<code>"`).
- Exact timestamp (milliseconds UTC)
- Memory at time of kill (`PSS` and `RSS` in KB)
- Process importance at time of kill (foreground, service, cached, etc.)
- Custom state blob via `setProcessStateSummary()`

**`setProcessStateSummary(byte[])`** — allows writing a small custom blob that the OS preserves across kills. **Limit: 128 bytes.** We use a compact encoding with abbreviated keys and epoch timestamps to fit within this limit. Written every 30 seconds during an active shift.

Compact blob format (fits in ~100 bytes):
```json
{"s":"shift-uuid","g":1710262180,"p":3,"b":12,"c":false,"t":1710262200}
```
Keys: `s`=shift_id, `g`=last_gps_at (epoch seconds), `p`=pending_points, `b`=battery_level (0-100), `c`=is_charging, `t`=timestamp (epoch seconds).

On API < 30: `getExitReasons` returns an empty list. No crash, no error.

### iOS (iOS 14+)

**MetricKit** provides two separate payload types:
- **`MXMetricPayload`** (via `didReceive(_ payloads: [MXMetricPayload])` or `pastPayloads`) — contains `MXAppExitMetric` with cumulative exit counts per category
- **`MXDiagnosticPayload`** (via `didReceive(_ payloads: [MXDiagnosticPayload])`) — contains crash diagnostics with call stack trees

Exit count categories:
- Foreground: normal, abnormal, memory_limit, memory_pressure, watchdog, cpu_limit, bad_access, illegal_instruction, suspended_locked_file
- Background: all of the above + background_task_timeout

Delivered immediately on next launch (iOS 15+). Delta computation against last-saved counters to detect new exits since last collection.

No equivalent to `setProcessStateSummary` on iOS.

## Architecture

### Native Layer

#### `ExitReasonPlugin.kt` (Android)

**MethodChannel:** `gps_tracker/exit_reason`

Registration pattern: static `register(messenger: BinaryMessenger, context: Context)` method, called from `MainActivity.configureFlutterEngine()` — same pattern as `DiagnosticNativePlugin.register()`.

| Method | Description |
|---|---|
| `getExitReasons` | Reads `ActivityManager.getHistoricalProcessExitReasons()`, filters to entries since last collected timestamp (stored in SharedPreferences), returns list of exit reason maps |
| `updateProcessState` | Calls `ActivityManager.setProcessStateSummary()` with compact JSON blob (≤128 bytes) |

Each exit reason map contains:
```json
{
  "reason": "low_memory",
  "reason_code": 3,
  "timestamp": 1710262200000,
  "description": "system kill for memory pressure",
  "importance": "cached",
  "importance_code": 400,
  "pss_kb": 280000,
  "rss_kb": 350000,
  "process_state_summary": "{\"s\":\"abc\",\"g\":1710262180,\"p\":3,\"b\":12,\"c\":false,\"t\":1710262200}"
}
```

Deduplication: after successful collection, saves the most recent exit timestamp to SharedPreferences key `exit_reason_last_collected_ts`. Next call only returns entries newer than this timestamp.

Unknown reason codes (from newer API levels) are mapped to `"unknown_<code>"` instead of crashing.

#### `ExitReasonPlugin.swift` (iOS)

**MethodChannel:** `gps_tracker/exit_reason`

**Important:** The existing `DiagnosticNativePlugin.swift` already subscribes to `MXMetricManager` for crash diagnostics and basic exit counts. To avoid duplicate subscriptions and double-counting:
- **Remove** MetricKit handling (`didReceive(_ payloads: [MXDiagnosticPayload])` and `metrickit_crash`/`metrickit_exit` events) from `DiagnosticNativePlugin.swift`
- **Consolidate** all MetricKit handling into `ExitReasonPlugin.swift`

The plugin subscribes to both `MXMetricManager` payload callbacks:
- `didReceive(_ payloads: [MXMetricPayload])` — for `MXAppExitMetric` exit counts
- `didReceive(_ payloads: [MXDiagnosticPayload])` — for crash diagnostics (replaces what was in DiagnosticNativePlugin)

| Method | Description |
|---|---|
| `getExitMetrics` | Reads `MXMetricManager.shared.pastPayloads` (iOS 14+) for exit counts, computes deltas against last-saved counters (UserDefaults). Also returns any pending crash diagnostics. |

Return format:
```json
{
  "foreground": {
    "normal": 2, "abnormal": 0, "memory_limit": 1,
    "memory_pressure": 0, "watchdog": 0, "cpu_limit": 0,
    "bad_access": 0, "illegal_instruction": 0, "suspended_locked_file": 0
  },
  "background": {
    "normal": 5, "abnormal": 0, "memory_limit": 0,
    "memory_pressure": 1, "watchdog": 0, "cpu_limit": 0,
    "bad_access": 0, "illegal_instruction": 0, "suspended_locked_file": 0,
    "background_task_timeout": 2
  },
  "crashes": [
    {"exception_code": "...", "signal": "...", "call_stack": "..."}
  ],
  "period_start": "2026-03-11T00:00:00Z",
  "period_end": "2026-03-12T00:00:00Z"
}
```

### Dart Layer

#### `ExitReasonCollector` (`lib/shared/services/exit_reason_collector.dart`)

Singleton service. Single public method:

```dart
static Future<void> collect(LocalDatabase localDb, String deviceId) async
```

**Flow:**
1. Call native `getExitReasons` (Android) or `getExitMetrics` (iOS)
2. Convert each result to `DiagnosticEvent`:
   - **Category:** `exitInfo` (new enum value)
   - **Severity:** `critical` for OOM/watchdog/ANR/crash, `warn` for user_requested/freezer, `info` for normal exit
   - **Message:** human-readable summary (e.g., "App killed: low_memory, PSS=245MB, importance=cached")
   - **Metadata:** full raw data from native (reason, timestamp, pss, rss, importance, process_state_summary, etc.)
3. Insert into SQLCipher via `LocalDatabase.insertDiagnosticEvent()` directly (bypasses `DiagnosticLogger`)
4. Native plugin updates its "last collected" marker

**Pre-auth handling:** `ExitReasonCollector` does NOT use `DiagnosticLogger` (which requires non-null `employeeId` and silently drops events otherwise). Instead, it calls `LocalDatabase.insertDiagnosticEvent()` directly, using `deviceId` as a **temporary** `employee_id`. These events are stored locally and wait for sync.

**Sync-time employee_id resolution:** The Supabase `diagnostic_logs` table has `employee_id UUID NOT NULL REFERENCES auth.users(id)` and the `sync_diagnostic_logs` RPC verifies `employee_id = auth.uid()`. A raw deviceId string would fail both the UUID cast and the ownership check. Therefore, `DiagnosticSyncService` must **replace** non-UUID `employee_id` values with the current `auth.uid()` before sending events to the RPC. This is a small modification: before building the `eventsJson` batch, check if `employee_id` is a valid UUID — if not, substitute the authenticated user's ID. This ensures events collected pre-auth are correctly attributed once the employee signs in.

#### Process State Writer

Integrated into the existing tracking loop (in `BackgroundExecutionService` or equivalent).

During an active shift, every **30 seconds** (Android only):
```dart
ExitReasonPlugin.updateProcessState({
  's': currentShiftId,
  'g': lastGpsTimestamp?.millisecondsSinceEpoch ~/ 1000,
  'p': unsyncedPointsCount,
  'b': batteryLevel,
  'c': isCharging,
  't': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
});
```

Fire-and-forget. No-op if no active shift. No-op on iOS.

### Modifications to Existing Code

| File | Change |
|---|---|
| `lib/shared/models/diagnostic_event.dart` | Add `exitInfo` to `EventCategory` enum |
| `lib/shared/services/local_database.dart` | **SQLCipher migration v10:** drop CHECK constraint on `event_category` column (recreate table without it). The existing CHECK only allows 9 categories but the enum already has 17 — categories like `battery`, `crash`, `memory`, `service`, `satellite`, `doze`, `motion`, `metrickit` are silently failing today. Remove the CHECK to allow any category string. |
| `lib/features/shifts/services/diagnostic_sync_service.dart` | Before syncing a batch, replace non-UUID `employee_id` values with the current `auth.uid()` (for pre-auth exit reason events). |
| `lib/main.dart` | Call `ExitReasonCollector.collect()` after LocalDatabase init (non-blocking, fire-and-forget). Runs before DiagnosticLogger init and before auth. |
| `lib/features/tracking/services/background_execution_service.dart` | Call `updateProcessState()` every 30s during active shift (Android only) |
| `android/.../MainActivity.kt` | Register `ExitReasonPlugin` via `ExitReasonPlugin.register(messenger, this)` |
| `ios/Runner/AppDelegate.swift` | Register `ExitReasonPlugin` |
| `ios/Runner.xcodeproj/project.pbxproj` | Add `ExitReasonPlugin.swift` to 4 PBX sections |
| `ios/Runner/DiagnosticNativePlugin.swift` | **Remove** MetricKit subscriber, `didReceive` callback, and `metrickit_crash`/`metrickit_exit` event emission (moved to ExitReasonPlugin) |
| `lib/shared/services/diagnostic_native_service.dart` | Remove the `metrickit_crash` and `metrickit_exit` case handlers from the event stream switch (lines 86-100). These events will no longer come from DiagnosticNativePlugin since MetricKit handling is consolidated into ExitReasonPlugin. |

### Supabase Migration Required

A new Supabase migration is needed to drop the `event_category` CHECK constraint on `diagnostic_logs`:

```sql
-- Drop the restrictive CHECK constraint that only allows 9 categories
-- (the enum already has 17+ categories, and new ones like exitInfo are being added)
ALTER TABLE diagnostic_logs DROP CONSTRAINT IF EXISTS diagnostic_logs_event_category_check;
```

The `severity` CHECK (`IN ('info', 'warn', 'error', 'critical')`) excludes `debug`, which is correct — debug events have `shouldSync = false` in Dart and are never sent to the server.

### No Changes Required

- **Supabase RPC** — `sync_diagnostic_logs` handles any event shape (no CHECK on insert, only the table constraint which we're removing)

## Offline Resilience

No special handling needed — the existing architecture already covers this:

1. **App killed while offline →** exit reasons preserved by the OS (not in our app's storage)
2. **App relaunched →** `ExitReasonCollector.collect()` reads from OS APIs → inserts into SQLCipher as `pending`
3. **Still offline →** events stay `pending` in SQLCipher indefinitely (encrypted, safe)
4. **Employee clocks in with connectivity →** sync cycle runs → `DiagnosticSyncService` pushes all `pending` events
5. **Multiple relaunches before sync →** each launch collects new exit reasons only (dedup via timestamp marker), all accumulate locally

## Data Gained vs. Today

| Signal | Today | After |
|---|---|---|
| Why the app was killed | Nothing (black hole) | Exact reason: Android per-event constants, iOS category counts |
| When exactly | Inferred from GPS gaps | Precise timestamp (Android) |
| Memory at time of kill | Nothing | PSS/RSS in KB (Android) |
| Tracking state at kill | Limited breadcrumbs | Full blob: shift_id, last GPS, pending points, battery |
| Battery correlation | Nothing | battery_level + is_charging in blob |
| Delivery | N/A | Fully automatic, zero employee action |

## Files to Create

| File | Purpose |
|---|---|
| `android/app/src/main/kotlin/ca/trilogis/gpstracker/ExitReasonPlugin.kt` | Android native: ApplicationExitInfo + setProcessStateSummary |
| `ios/Runner/ExitReasonPlugin.swift` | iOS native: MetricKit consolidated (exit counts + crash diagnostics) |
| `lib/shared/services/exit_reason_collector.dart` | Dart service: collect on launch, convert to DiagnosticEvent, insert directly into LocalDatabase |
