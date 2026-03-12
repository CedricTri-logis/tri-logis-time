# Exit Reason Collection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically collect OS exit reasons (ApplicationExitInfo on Android, MetricKit on iOS) at app launch, store locally in SQLCipher, and sync to Supabase through the existing diagnostic pipeline.

**Architecture:** New `ExitReasonPlugin` (Kotlin + Swift) exposes native exit data via MethodChannel. Dart `ExitReasonCollector` service calls the plugin at app launch, converts results to `DiagnosticEvent` entries, and inserts them directly into `LocalDatabase`. Existing `DiagnosticSyncService` handles upload. On Android, process state is written every 30s from the **main isolate** (in `TrackingProvider._handleHeartbeat()`) since MethodChannels are only available on the main engine — the background `GPSTrackingHandler` sends heartbeat data to main via `FlutterForegroundTask.sendDataToMain()`.

**Tech Stack:** Kotlin (Android native), Swift (iOS native), Dart/Flutter (service layer), SQLCipher (local storage), Supabase PostgreSQL (server)

**Spec:** `docs/superpowers/specs/2026-03-12-exit-reason-collection-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `android/app/src/main/kotlin/ca/trilogis/gpstracker/ExitReasonPlugin.kt` | Create | Android native: read `ApplicationExitInfo`, write `setProcessStateSummary()` |
| `ios/Runner/ExitReasonPlugin.swift` | Create | iOS native: read MetricKit `MXAppExitMetric` + crash diagnostics |
| `lib/shared/services/exit_reason_collector.dart` | Create | Dart service: call native plugin, convert to DiagnosticEvent, insert into LocalDatabase |
| `lib/shared/models/diagnostic_event.dart` | Modify | Add `exitInfo` to `EventCategory` enum |
| `lib/shared/services/local_database.dart` | Modify | SQLCipher migration v10: drop `event_category` CHECK constraint |
| `lib/features/shifts/services/diagnostic_sync_service.dart` | Modify | Replace non-UUID `employee_id` with `auth.uid()` before sync |
| `lib/shared/services/diagnostic_native_service.dart` | Modify | Remove `metrickit_crash`/`metrickit_exit` case handlers |
| `ios/Runner/DiagnosticNativePlugin.swift` | Modify | Remove MetricKit subscriber (moved to ExitReasonPlugin) |
| `android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt` | Modify | Register ExitReasonPlugin |
| `ios/Runner/AppDelegate.swift` | Modify | Register ExitReasonPlugin |
| `ios/Runner.xcodeproj/project.pbxproj` | Modify | Add ExitReasonPlugin.swift to 4 PBX sections |
| `lib/main.dart` | Modify | Call `ExitReasonCollector.collect()` at startup |
| `lib/features/tracking/providers/tracking_provider.dart` | Modify | Call `updateProcessState()` in `_handleHeartbeat()` (main isolate, every 30s) |
| `supabase/migrations/XXX_drop_diagnostic_event_category_check.sql` | Create | Drop server-side CHECK constraint |

---

## Chunk 1: Dart Foundation (EventCategory + SQLCipher Migration + DiagnosticSyncService fix)

### Task 1: Add `exitInfo` to EventCategory enum

**Files:**
- Modify: `gps_tracker/lib/shared/models/diagnostic_event.dart:6-26`

- [ ] **Step 1: Add the enum value**

In `diagnostic_event.dart`, add `exitInfo` after `metrickit` in the `EventCategory` enum:

```dart
enum EventCategory {
  gps,
  shift,
  sync,
  auth,
  permission,
  lifecycle,
  thermal,
  error,
  network,
  battery,
  crash,
  memory,
  service,
  satellite,
  doze,
  motion,
  metrickit,
  exitInfo;

  String get value => name;
}
```

- [ ] **Step 2: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/shared/models/diagnostic_event.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/shared/models/diagnostic_event.dart
git commit -m "feat: add exitInfo to EventCategory enum"
```

### Task 2: SQLCipher migration v10 — drop event_category CHECK

**Files:**
- Modify: `gps_tracker/lib/shared/services/local_database.dart:27` (version bump)
- Modify: `gps_tracker/lib/shared/services/local_database.dart:388-418` (table recreation)
- Modify: `gps_tracker/lib/shared/services/local_database.dart:490-493` (add migration v10)

- [ ] **Step 1: Bump database version**

Change line 27:
```dart
static const int _databaseVersion = 10;
```

- [ ] **Step 2: Update `_createDiagnosticEventsTable` to remove CHECK on event_category**

Replace the `_createDiagnosticEventsTable` method. Remove the CHECK constraint on `event_category` (keep the CHECK on `severity` and `sync_status` — those are stable):

```dart
Future<void> _createDiagnosticEventsTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS diagnostic_events (
      id TEXT PRIMARY KEY,
      employee_id TEXT NOT NULL,
      shift_id TEXT,
      device_id TEXT NOT NULL,
      event_category TEXT NOT NULL,
      severity TEXT NOT NULL CHECK (severity IN ('debug', 'info', 'warn', 'error', 'critical')),
      message TEXT NOT NULL,
      metadata TEXT,
      app_version TEXT NOT NULL,
      platform TEXT NOT NULL,
      os_version TEXT,
      sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_diag_sync_status ON diagnostic_events(sync_status)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_diag_created_at ON diagnostic_events(created_at)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_diag_category_severity ON diagnostic_events(event_category, severity)
  ''');
}
```

- [ ] **Step 3: Add migration v10 in `_onUpgrade`**

After the `if (oldVersion < 9)` block (line ~493), add:

```dart
// Migration from v9 to v10: Remove restrictive event_category CHECK constraint
// The CHECK only allowed 9 categories but the enum has 18+ values.
// SQLite doesn't support DROP CONSTRAINT, so we recreate the table.
if (oldVersion < 10) {
  await _migrateDiagnosticEventsDropCheck(db);
}
```

- [ ] **Step 4: Add the migration helper method**

Add this method to `LocalDatabase` (after `_addExtendedGpsColumns`):

```dart
/// Recreate diagnostic_events table without the restrictive event_category CHECK.
Future<void> _migrateDiagnosticEventsDropCheck(Database db) async {
  // 1. Rename old table
  await db.execute('ALTER TABLE diagnostic_events RENAME TO diagnostic_events_old');

  // 2. Create new table without event_category CHECK
  await _createDiagnosticEventsTable(db);

  // 3. Copy data
  await db.execute('''
    INSERT INTO diagnostic_events
    SELECT * FROM diagnostic_events_old
  ''');

  // 4. Drop old table
  await db.execute('DROP TABLE diagnostic_events_old');
}
```

- [ ] **Step 5: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/shared/services/local_database.dart`
Expected: No issues found

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/shared/services/local_database.dart
git commit -m "feat: SQLCipher migration v10 - drop event_category CHECK constraint"
```

### Task 3: Fix DiagnosticSyncService to replace non-UUID employee_id

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/diagnostic_sync_service.dart:22-34`

- [ ] **Step 1: Add UUID validation and employee_id replacement**

Replace the `syncDiagnosticEvents` method body. The key change is at the `eventsJson` building step — replace non-UUID `employee_id` with the authenticated user's ID:

```dart
Future<int> syncDiagnosticEvents() async {
  int totalSynced = 0;

  try {
    // Get current authenticated user ID for employee_id resolution
    final currentUserId = _supabase.auth.currentUser?.id;
    if (currentUserId == null) return 0; // Not authenticated — skip sync

    while (true) {
      final pending = await _localDb.getPendingDiagnosticEvents(
        limit: _batchSize,
      );

      if (pending.isEmpty) break;

      // Build JSON, replacing non-UUID employee_id with authenticated user's ID
      final eventsJson = pending.map((e) {
        final json = e.toJson();
        // If employee_id is not a valid UUID (e.g., deviceId from pre-auth collection),
        // replace with the current authenticated user's ID
        final employeeId = json['employee_id'] as String?;
        if (employeeId != null && !_isValidUuid(employeeId)) {
          json['employee_id'] = currentUserId;
        }
        return json;
      }).toList();

      try {
        final result = await _supabase.rpc<Map<String, dynamic>>(
          'sync_diagnostic_logs',
          params: {'p_events': eventsJson},
        );

        if (result['status'] == 'success') {
          final inserted = result['inserted'] as int? ?? 0;
          final duplicates = result['duplicates'] as int? ?? 0;
          totalSynced += inserted + duplicates;

          // Mark all events in this batch as synced
          final ids = pending.map((e) => e.id).toList();
          await _localDb.markDiagnosticEventsSynced(ids);
        } else {
          // Server returned error — stop and retry next cycle
          debugPrint('[DiagSync] Server error: ${result['message']}');
          break;
        }
      } catch (e) {
        // Network error — stop and retry next cycle
        debugPrint('[DiagSync] Sync failed: $e');
        break;
      }
    }

    // Prune old synced events to stay under storage limit
    await _localDb.pruneDiagnosticEvents();
  } catch (e) {
    debugPrint('[DiagSync] Unexpected error: $e');
  }

  return totalSynced;
}

/// Check if a string is a valid UUID v4 format.
static bool _isValidUuid(String s) {
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(s);
}
```

- [ ] **Step 2: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/services/diagnostic_sync_service.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/diagnostic_sync_service.dart
git commit -m "feat: resolve pre-auth employee_id in DiagnosticSyncService"
```

### Task 4: Supabase migration — drop server-side event_category CHECK

**Files:**
- Create: `supabase/migrations/XXX_drop_diagnostic_event_category_check.sql`

Note: determine the next migration number by listing `supabase/migrations/` and incrementing.

- [ ] **Step 1: Find next migration number**

Run: `ls supabase/migrations/ | tail -1`
Use the next sequential number.

- [ ] **Step 2: Create the migration file**

```sql
-- Drop the restrictive event_category CHECK on diagnostic_logs.
-- The CHECK only allowed 9 categories but the app already uses 18+.
-- New categories (exitInfo, battery, crash, memory, service, satellite, doze, motion, metrickit)
-- were silently failing on insert.

ALTER TABLE diagnostic_logs DROP CONSTRAINT IF EXISTS diagnostic_logs_event_category_check;
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/XXX_drop_diagnostic_event_category_check.sql
git commit -m "feat: drop event_category CHECK constraint on diagnostic_logs"
```

---

## Chunk 2: Android Native — ExitReasonPlugin.kt

### Task 5: Create ExitReasonPlugin.kt

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/ExitReasonPlugin.kt`

- [ ] **Step 1: Create the plugin file**

```kotlin
package ca.trilogis.gpstracker

import android.app.ActivityManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class ExitReasonPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "gps_tracker/exit_reason"
        private const val PREFS_NAME = "exit_reason_prefs"
        private const val KEY_LAST_COLLECTED_TS = "exit_reason_last_collected_ts"
        private const val MAX_RESULTS = 30

        fun register(messenger: BinaryMessenger, context: Context) {
            val plugin = ExitReasonPlugin(context)
            plugin.setupChannel(messenger)
        }
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun setupChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getExitReasons" -> {
                    result.success(getExitReasons())
                }
                "updateProcessState" -> {
                    val jsonString = call.argument<String>("state") ?: ""
                    updateProcessState(jsonString)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Read ApplicationExitInfo entries since last collection.
     * Returns a list of maps, each describing one exit event.
     * Returns empty list on API < 30.
     */
    private fun getExitReasons(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return emptyList()
        }

        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exitInfos = am.getHistoricalProcessExitReasons(
                context.packageName, 0, MAX_RESULTS
            )

            val lastCollectedTs = prefs.getLong(KEY_LAST_COLLECTED_TS, 0L)
            var maxTimestamp = lastCollectedTs

            val results = mutableListOf<Map<String, Any?>>()

            for (info in exitInfos) {
                if (info.timestamp <= lastCollectedTs) continue

                if (info.timestamp > maxTimestamp) {
                    maxTimestamp = info.timestamp
                }

                val stateBytes = try {
                    info.processStateSummary
                } catch (_: Exception) {
                    null
                }

                results.add(mapOf(
                    "reason" to reasonToString(info.reason),
                    "reason_code" to info.reason,
                    "timestamp" to info.timestamp,
                    "description" to (info.description ?: ""),
                    "importance" to importanceToString(info.importance),
                    "importance_code" to info.importance,
                    "pss_kb" to info.pss,
                    "rss_kb" to info.rss,
                    "status" to info.status,
                    "process_state_summary" to stateBytes?.let { String(it) }
                ))
            }

            // Save the most recent timestamp for deduplication
            if (maxTimestamp > lastCollectedTs) {
                prefs.edit().putLong(KEY_LAST_COLLECTED_TS, maxTimestamp).apply()
            }

            results
        } catch (e: Exception) {
            android.util.Log.e("ExitReasonPlugin", "Failed to get exit reasons", e)
            emptyList()
        }
    }

    /**
     * Write custom state blob via setProcessStateSummary().
     * The OS preserves this data across process kills.
     * Limit: 128 bytes. Caller must send compact JSON.
     */
    private fun updateProcessState(jsonString: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        try {
            val bytes = jsonString.toByteArray(Charsets.UTF_8)
            if (bytes.size > 128) {
                android.util.Log.w(
                    "ExitReasonPlugin",
                    "Process state too large (${bytes.size} bytes > 128), truncating"
                )
                val truncated = jsonString.toByteArray(Charsets.UTF_8).copyOf(128)
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                am.setProcessStateSummary(truncated)
            } else {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                am.setProcessStateSummary(bytes)
            }
        } catch (e: Exception) {
            android.util.Log.e("ExitReasonPlugin", "Failed to update process state", e)
        }
    }

    private fun reasonToString(reason: Int): String = when (reason) {
        0 -> "unknown"
        1 -> "exit_self"
        2 -> "signaled"
        3 -> "low_memory"
        4 -> "crash"
        5 -> "crash_native"
        6 -> "anr"
        7 -> "initialization_failure"
        8 -> "permission_change"
        9 -> "excessive_resource_usage"
        10 -> "user_requested"
        11 -> "user_stopped"
        12 -> "dependency_died"
        13 -> "other"
        14 -> "freezer"
        15 -> "package_state_change"
        16 -> "package_updated"
        else -> "unknown_$reason"
    }

    private fun importanceToString(importance: Int): String = when {
        importance <= 100 -> "foreground"
        importance <= 125 -> "foreground_service"
        importance <= 150 -> "visible"
        importance <= 200 -> "service"
        importance <= 300 -> "top_sleeping"
        importance <= 325 -> "cant_save_state"
        importance <= 400 -> "cached"
        importance <= 1000 -> "gone"
        else -> "unknown_$importance"
    }
}
```

- [ ] **Step 2: Register plugin in MainActivity.kt**

In `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`, after the `DiagnosticNativePlugin.register` line (line 124), add:

```kotlin
// --- Exit Reason Plugin (ApplicationExitInfo + process state) ---
ExitReasonPlugin.register(flutterEngine.dartExecutor.binaryMessenger, this)
```

- [ ] **Step 3: Verify Android compiles**

Run: `cd gps_tracker && flutter build apk --debug 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/ExitReasonPlugin.kt
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat: Android ExitReasonPlugin - ApplicationExitInfo + setProcessStateSummary"
```

---

## Chunk 3: iOS Native — ExitReasonPlugin.swift + DiagnosticNativePlugin cleanup

### Task 6: Create ExitReasonPlugin.swift

**Files:**
- Create: `gps_tracker/ios/Runner/ExitReasonPlugin.swift`

- [ ] **Step 1: Create the plugin file**

```swift
import Flutter
import UIKit
import MetricKit

public class ExitReasonPlugin: NSObject, FlutterPlugin, MXMetricManagerSubscriber {

    private var channel: FlutterMethodChannel?
    private var pendingCrashes: [[String: Any]] = []
    private var pendingExitMetrics: [[String: Any]] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ExitReasonPlugin()
        let channel = FlutterMethodChannel(
            name: "gps_tracker/exit_reason",
            binaryMessenger: registrar.messenger()
        )
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Subscribe to MetricKit (replaces subscription in DiagnosticNativePlugin)
        if #available(iOS 13, *) {
            MXMetricManager.shared.add(instance)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getExitMetrics":
            result(getExitMetrics())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Exit Metrics Collection

    private func getExitMetrics() -> [String: Any] {
        var response: [String: Any] = [
            "foreground": [:] as [String: Any],
            "background": [:] as [String: Any],
            "crashes": [] as [[String: Any]]
        ]

        // Return any pending crashes collected by MetricKit callbacks
        if !pendingCrashes.isEmpty {
            response["crashes"] = pendingCrashes
            pendingCrashes.removeAll()
        }

        // Read exit metrics from pastPayloads (iOS 14+)
        if #available(iOS 14, *) {
            let payloads = MXMetricManager.shared.pastPayloads
            let exitMetrics = extractExitMetrics(from: payloads)
            response["foreground"] = exitMetrics["foreground"] ?? [:]
            response["background"] = exitMetrics["background"] ?? [:]
            if let periodStart = exitMetrics["period_start"] {
                response["period_start"] = periodStart
            }
            if let periodEnd = exitMetrics["period_end"] {
                response["period_end"] = periodEnd
            }
        }

        return response
    }

    @available(iOS 14, *)
    private func extractExitMetrics(from payloads: [MXMetricPayload]) -> [String: Any] {
        let defaults = UserDefaults.standard
        let prefix = "exit_reason_last_"

        // Aggregate across all payloads
        var foreground: [String: Int] = [:]
        var background: [String: Int] = [:]
        var periodStart: String?
        var periodEnd: String?

        let formatter = ISO8601DateFormatter()

        for payload in payloads {
            let s = formatter.string(from: payload.timeStampBegin)
            if periodStart == nil || s < periodStart! { periodStart = s }

            let e = formatter.string(from: payload.timeStampEnd)
            if periodEnd == nil || e > periodEnd! { periodEnd = e }

            if #available(iOS 15, *) {
                if let exitMetric = payload.applicationExitMetrics {
                    // Foreground exits
                    let fg = exitMetric.foregroundExitData
                    foreground["normal"] = (foreground["normal"] ?? 0) + fg.cumulativeNormalAppExitCount
                    foreground["abnormal"] = (foreground["abnormal"] ?? 0) + fg.cumulativeAbnormalExitCount
                    foreground["memory_limit"] = (foreground["memory_limit"] ?? 0) + fg.cumulativeMemoryResourceLimitExitCount
                    foreground["memory_pressure"] = (foreground["memory_pressure"] ?? 0) + fg.cumulativeMemoryPressureExitCount
                    foreground["watchdog"] = (foreground["watchdog"] ?? 0) + fg.cumulativeAppWatchdogExitCount
                    foreground["cpu_limit"] = (foreground["cpu_limit"] ?? 0) + fg.cumulativeCPUResourceLimitExitCount
                    foreground["bad_access"] = (foreground["bad_access"] ?? 0) + fg.cumulativeBadAccessExitCount
                    foreground["illegal_instruction"] = (foreground["illegal_instruction"] ?? 0) + fg.cumulativeIllegalInstructionExitCount
                    foreground["suspended_locked_file"] = (foreground["suspended_locked_file"] ?? 0) + fg.cumulativeSuspendedWithLockedFileExitCount

                    // Background exits
                    let bg = exitMetric.backgroundExitData
                    background["normal"] = (background["normal"] ?? 0) + bg.cumulativeNormalAppExitCount
                    background["abnormal"] = (background["abnormal"] ?? 0) + bg.cumulativeAbnormalExitCount
                    background["memory_limit"] = (background["memory_limit"] ?? 0) + bg.cumulativeMemoryResourceLimitExitCount
                    background["memory_pressure"] = (background["memory_pressure"] ?? 0) + bg.cumulativeMemoryPressureExitCount
                    background["watchdog"] = (background["watchdog"] ?? 0) + bg.cumulativeAppWatchdogExitCount
                    background["cpu_limit"] = (background["cpu_limit"] ?? 0) + bg.cumulativeCPUResourceLimitExitCount
                    background["bad_access"] = (background["bad_access"] ?? 0) + bg.cumulativeBadAccessExitCount
                    background["illegal_instruction"] = (background["illegal_instruction"] ?? 0) + bg.cumulativeIllegalInstructionExitCount
                    background["suspended_locked_file"] = (background["suspended_locked_file"] ?? 0) + bg.cumulativeSuspendedWithLockedFileExitCount
                    background["background_task_timeout"] = (background["background_task_timeout"] ?? 0) + bg.cumulativeBackgroundTaskAssertionTimeoutExitCount
                }
            }
        }

        // Compute deltas against last-saved counters
        var fgDeltas: [String: Int] = [:]
        for (key, total) in foreground {
            let lastKey = "\(prefix)fg_\(key)"
            let lastValue = defaults.integer(forKey: lastKey)
            let delta = max(0, total - lastValue)
            if delta > 0 { fgDeltas[key] = delta }
            defaults.set(total, forKey: lastKey)
        }

        var bgDeltas: [String: Int] = [:]
        for (key, total) in background {
            let lastKey = "\(prefix)bg_\(key)"
            let lastValue = defaults.integer(forKey: lastKey)
            let delta = max(0, total - lastValue)
            if delta > 0 { bgDeltas[key] = delta }
            defaults.set(total, forKey: lastKey)
        }

        var result: [String: Any] = [
            "foreground": fgDeltas,
            "background": bgDeltas
        ]
        if let ps = periodStart { result["period_start"] = ps }
        if let pe = periodEnd { result["period_end"] = pe }

        return result
    }

    // MARK: - MXMetricManagerSubscriber

    @available(iOS 14, *)
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Buffer crash diagnostics for next getExitMetrics() call
        for payload in payloads {
            do {
                let json = payload.jsonRepresentation()
                if let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    if let crashes = dict["crashDiagnostics"] as? [[String: Any]] {
                        pendingCrashes.append(contentsOf: crashes)
                    }
                }
            } catch {
                // Silently ignore
            }
        }
    }

    @available(iOS 13, *)
    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Metric payloads are read on-demand via pastPayloads in getExitMetrics()
        // No buffering needed here — just log for debugging
    }
}
```

- [ ] **Step 2: Add to Xcode project**

The `ExitReasonPlugin.swift` file must be added to `ios/Runner.xcodeproj/project.pbxproj` in 4 PBX sections:
1. PBXBuildFile section
2. PBXFileReference section
3. PBXGroup children (Runner group)
4. PBXSourcesBuildPhase files list

Use the same UUIDs pattern as other plugin files. The implementer should use the Xcode project file structure as reference — look at how `BackgroundTaskPlugin.swift` is registered and follow the same pattern with new UUIDs.

- [ ] **Step 3: Register in AppDelegate.swift**

In `gps_tracker/ios/Runner/AppDelegate.swift`, after the DiagnosticNativePlugin registration (line 36), add:

```swift
// Register Exit Reason plugin (MetricKit exit counts + crash diagnostics)
ExitReasonPlugin.register(with: self.registrar(forPlugin: "ExitReasonPlugin")!)
```

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/ios/Runner/ExitReasonPlugin.swift
git add gps_tracker/ios/Runner.xcodeproj/project.pbxproj
git add gps_tracker/ios/Runner/AppDelegate.swift
git commit -m "feat: iOS ExitReasonPlugin - MetricKit exit counts + crash diagnostics"
```

### Task 7: Remove MetricKit from DiagnosticNativePlugin.swift

**Files:**
- Modify: `gps_tracker/ios/Runner/DiagnosticNativePlugin.swift`

- [ ] **Step 1: Remove MetricKit from DiagnosticNativePlugin**

Remove the `MXMetricManagerSubscriber` protocol conformance and all MetricKit-related code:

1. Line 4: Remove `import MetricKit` (ExitReasonPlugin now imports it)
2. Line 6-7: Remove `MXMetricManagerSubscriber` from the protocol list:
   ```swift
   public class DiagnosticNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
       CLLocationManagerDelegate {
   ```
3. Lines 26: Remove `startMetricKit()` call from `onListen`
4. Lines 40-44: Delete `startMetricKit()` method
5. Lines 46-69: Delete `didReceive(_ payloads: [MXDiagnosticPayload])` method
6. Lines 123-125: Remove `MXMetricManager.shared.remove(self)` from `stopAll()`

The remaining code (location pause/resume monitoring, memory pressure monitoring) stays.

- [ ] **Step 2: Update diagnostic_native_service.dart**

In `gps_tracker/lib/shared/services/diagnostic_native_service.dart`, remove the `metrickit_crash` and `metrickit_exit` case handlers (lines 85-100):

Delete these two cases from the switch statement:
```dart
// DELETE: iOS: MetricKit crash diagnostic
case 'metrickit_crash':
  ...

// DELETE: iOS: MetricKit app exit reasons
case 'metrickit_exit':
  ...
```

- [ ] **Step 3: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/shared/services/diagnostic_native_service.dart`
Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/ios/Runner/DiagnosticNativePlugin.swift
git add gps_tracker/lib/shared/services/diagnostic_native_service.dart
git commit -m "refactor: move MetricKit handling from DiagnosticNativePlugin to ExitReasonPlugin"
```

---

## Chunk 4: Dart Service — ExitReasonCollector + Integration

### Task 8: Create ExitReasonCollector service

**Files:**
- Create: `gps_tracker/lib/shared/services/exit_reason_collector.dart`

- [ ] **Step 1: Create the collector service**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/diagnostic_event.dart';
import 'local_database.dart';

/// Collects OS exit reasons on app launch and stores them as DiagnosticEvents.
///
/// Android: reads ApplicationExitInfo (API 30+) — per-event with timestamps.
/// iOS: reads MetricKit MXAppExitMetric (iOS 14+) — cumulative delta counts.
///
/// Bypasses DiagnosticLogger (which requires non-null employeeId) and inserts
/// directly into LocalDatabase. The deviceId is used as a temporary employee_id;
/// DiagnosticSyncService replaces it with auth.uid() at sync time.
///
/// Fire-and-forget: never blocks app startup, never throws.
class ExitReasonCollector {
  static const _channel = MethodChannel('gps_tracker/exit_reason');

  /// Collect exit reasons from the OS and store as diagnostic events.
  /// Call once at app launch, after LocalDatabase is initialized.
  static Future<void> collect(LocalDatabase localDb, String deviceId) async {
    try {
      if (Platform.isAndroid) {
        await _collectAndroid(localDb, deviceId);
      } else if (Platform.isIOS) {
        await _collectIOS(localDb, deviceId);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ExitReasonCollector] Failed to collect: $e');
      }
    }
  }

  /// Update the process state summary (Android only).
  /// Called periodically during an active shift.
  static Future<void> updateProcessState(Map<String, dynamic> state) async {
    if (!Platform.isAndroid) return;

    try {
      final jsonString = jsonEncode(state);
      await _channel.invokeMethod('updateProcessState', {'state': jsonString});
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ExitReasonCollector] Failed to update process state: $e');
      }
    }
  }

  static Future<void> _collectAndroid(LocalDatabase localDb, String deviceId) async {
    final results = await _channel.invokeMethod<List<dynamic>>('getExitReasons');
    if (results == null || results.isEmpty) return;

    final appVersion = await _getAppVersion();
    final osVersion = await _getOsVersion();

    for (final raw in results) {
      final info = Map<String, dynamic>.from(raw as Map);
      final reason = info['reason'] as String? ?? 'unknown';
      final reasonCode = info['reason_code'] as int? ?? 0;
      final pssKb = info['pss_kb'] as int? ?? 0;
      final importance = info['importance'] as String? ?? 'unknown';
      final description = info['description'] as String? ?? '';
      final timestamp = info['timestamp'] as int? ?? 0;

      final severity = _severityForReason(reason);
      final pssMb = pssKb > 0 ? '${(pssKb / 1024).toStringAsFixed(0)}MB' : 'N/A';

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId, // Temporary — replaced at sync time
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: severity,
        message: 'App killed: $reason, PSS=$pssMb, importance=$importance',
        metadata: {
          'reason': reason,
          'reason_code': reasonCode,
          'exit_timestamp': timestamp,
          'description': description,
          'importance': importance,
          'importance_code': info['importance_code'],
          'pss_kb': pssKb,
          'rss_kb': info['rss_kb'],
          'status': info['status'],
          'process_state_summary': info['process_state_summary'],
        },
        appVersion: appVersion,
        platform: 'android',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    if (kDebugMode) {
      debugPrint('[ExitReasonCollector] Collected ${results.length} Android exit reasons');
    }
  }

  static Future<void> _collectIOS(LocalDatabase localDb, String deviceId) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getExitMetrics');
    if (result == null) return;

    final data = Map<String, dynamic>.from(result);
    final foreground = data['foreground'] as Map? ?? {};
    final background = data['background'] as Map? ?? {};
    final crashes = data['crashes'] as List? ?? [];

    final appVersion = await _getAppVersion();
    final osVersion = await _getOsVersion();

    // Check if there are any non-zero deltas
    final hasForegroundExits = foreground.values.any((v) => v is int && v > 0);
    final hasBackgroundExits = background.values.any((v) => v is int && v > 0);

    if (hasForegroundExits || hasBackgroundExits) {
      // Create one summary event with all exit count deltas
      final severity = _iosExitSeverity(foreground, background);

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId,
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: severity,
        message: _iosExitMessage(foreground, background),
        metadata: {
          'foreground': Map<String, dynamic>.from(foreground),
          'background': Map<String, dynamic>.from(background),
          if (data['period_start'] != null) 'period_start': data['period_start'],
          if (data['period_end'] != null) 'period_end': data['period_end'],
        },
        appVersion: appVersion,
        platform: 'ios',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    // Create separate events for each crash diagnostic
    for (final crash in crashes) {
      final crashData = Map<String, dynamic>.from(crash as Map);

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId,
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: Severity.critical,
        message: 'MetricKit crash diagnostic',
        metadata: crashData,
        appVersion: appVersion,
        platform: 'ios',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    if (kDebugMode) {
      final count = (hasForegroundExits || hasBackgroundExits ? 1 : 0) + crashes.length;
      if (count > 0) {
        debugPrint('[ExitReasonCollector] Collected $count iOS exit metric events');
      }
    }
  }

  /// Map Android exit reason to severity.
  static Severity _severityForReason(String reason) {
    switch (reason) {
      case 'low_memory':
      case 'crash':
      case 'crash_native':
      case 'anr':
      case 'excessive_resource_usage':
      case 'initialization_failure':
        return Severity.critical;
      case 'user_requested':
      case 'user_stopped':
      case 'freezer':
      case 'signaled':
        return Severity.warn;
      case 'exit_self':
      case 'other':
      case 'permission_change':
      case 'dependency_died':
      case 'package_state_change':
      case 'package_updated':
        return Severity.info;
      default:
        return Severity.warn;
    }
  }

  /// Determine severity from iOS exit count deltas.
  static Severity _iosExitSeverity(Map foreground, Map background) {
    final criticalKeys = [
      'memory_limit', 'memory_pressure', 'watchdog', 'cpu_limit',
      'bad_access', 'illegal_instruction', 'abnormal', 'background_task_timeout'
    ];
    for (final key in criticalKeys) {
      if ((foreground[key] as int? ?? 0) > 0) return Severity.critical;
      if ((background[key] as int? ?? 0) > 0) return Severity.critical;
    }
    return Severity.info;
  }

  /// Build human-readable message from iOS exit deltas.
  static String _iosExitMessage(Map foreground, Map background) {
    final parts = <String>[];
    foreground.forEach((key, value) {
      if (value is int && value > 0) parts.add('fg_$key=$value');
    });
    background.forEach((key, value) {
      if (value is int && value > 0) parts.add('bg_$key=$value');
    });
    return parts.isEmpty ? 'iOS exit metrics (no deltas)' : 'iOS exits: ${parts.join(', ')}';
  }

  static Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  static Future<String?> _getOsVersion() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        return '${ios.systemName} ${ios.systemVersion}';
      } else {
        final android = await deviceInfo.androidInfo;
        return 'Android ${android.version.release} (SDK ${android.version.sdkInt})';
      }
    } catch (_) {
      return null;
    }
  }
}
```

- [ ] **Step 2: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/shared/services/exit_reason_collector.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/shared/services/exit_reason_collector.dart
git commit -m "feat: add ExitReasonCollector Dart service"
```

### Task 9: Integrate into main.dart startup

**Files:**
- Modify: `gps_tracker/lib/main.dart:23-27` (imports)
- Modify: `gps_tracker/lib/main.dart:163-187` (diagnostic init block)

- [ ] **Step 1: Add import**

Add at the imports section (after line 23):
```dart
import 'shared/services/exit_reason_collector.dart';
```

- [ ] **Step 2: Call ExitReasonCollector.collect() after LocalDatabase init**

In the diagnostic logger init block (around line 163), add the exit reason collection BEFORE the logger init. Insert after the `NotificationService` try/catch (after line 161) and before the diagnostic logger try block (line 163):

```dart
// Collect OS exit reasons (non-critical, fire-and-forget)
// Must run after LocalDatabase init but before auth is required.
try {
  final deviceId = await DeviceIdService.getDeviceId();
  await ExitReasonCollector.collect(LocalDatabase(), deviceId);
} catch (e) {
  debugPrint('[Main] ExitReasonCollector failed (non-critical): $e');
}
```

Also add the import for `DeviceIdService` if not already present:
```dart
import 'features/auth/services/device_id_service.dart';
```

- [ ] **Step 3: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/main.dart`
Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/main.dart
git commit -m "feat: call ExitReasonCollector.collect() at app startup"
```

### Task 10: Add process state writing to TrackingProvider (main isolate)

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` (imports + _handleHeartbeat)

**Why main isolate, not background?** `GPSTrackingHandler` runs in a **background isolate** where MethodChannels registered on the main Flutter engine are not available (`MissingPluginException`). The handler already sends heartbeat data to the main isolate every 30s via `FlutterForegroundTask.sendDataToMain()`. The main isolate's `TrackingProvider._handleHeartbeat()` receives this data and has full access to MethodChannels.

- [ ] **Step 1: Add import**

Add to the imports in `tracking_provider.dart`:
```dart
import '../../../shared/services/exit_reason_collector.dart';
```

- [ ] **Step 2: Add process state update in _handleHeartbeat**

In the `_handleHeartbeat(Map<String, dynamic> data)` method (around line 373), at the END of the method, add:

```dart
// Update process state summary for OS exit reason recovery (Android only).
// Called every 30s from the heartbeat cycle. Battery info is not available
// from the background handler, so we pass null — the primary value is
// shift_id + last GPS timestamp + pending points for debugging kills.
if (Platform.isAndroid && state.activeShiftId != null) {
  ExitReasonCollector.updateProcessState({
    's': state.activeShiftId!,
    'g': _lastBackgroundCapture?.millisecondsSinceEpoch != null
        ? (_lastBackgroundCapture!.millisecondsSinceEpoch ~/ 1000)
        : null,
    'p': data['point_count'] as int? ?? 0,
    'b': null, // Battery not available in heartbeat data
    'c': null, // Charging not available in heartbeat data
    't': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
  });
}
```

- [ ] **Step 3: Add `dart:io` import if not present**

Check if `import 'dart:io';` is already in the file. If not, add it.

- [ ] **Step 4: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/providers/tracking_provider.dart`
Expected: No issues found

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat: write process state summary every 30s from main isolate heartbeat"
```

---

## Chunk 5: Final Verification

### Task 11: Full project build verification

- [ ] **Step 1: Run flutter analyze on entire project**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found (or only pre-existing warnings)

- [ ] **Step 2: Run flutter tests**

Run: `cd gps_tracker && flutter test`
Expected: All tests pass

- [ ] **Step 3: Verify Android builds**

Run: `cd gps_tracker && flutter build apk --debug 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Final commit if any fixups needed**

If any issues were found and fixed:
```bash
git add -A
git commit -m "fix: resolve build issues from exit reason collection feature"
```
