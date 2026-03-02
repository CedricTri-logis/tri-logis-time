# Remove android_alarm_manager_plus — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove `android_alarm_manager_plus` to fix Android 16 (SDK 36) `RebootBroadcastReceiver` crash that corrupts the GPS foreground service on 100% of Android 16 devices.

**Architecture:** Remove the AlarmManager watchdog layer entirely, promote WorkManager from 15-min backup to 5-min primary. The foreground service, GPS self-healing, app resume check, and boot receiver all remain unchanged.

**Tech Stack:** Dart/Flutter, flutter_foreground_task, workmanager (existing)

---

### Task 1: Remove `android_alarm_manager_plus` from TrackingWatchdogService

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart`

**Step 1: Rewrite the file without AlarmManager**

Replace the entire file content with:

```dart
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import 'background_tracking_service.dart';

/// Watchdog service that detects and restarts the GPS foreground service
/// if Android kills it during an active shift.
///
/// Uses WorkManager periodic task (5 min) as the sole watchdog mechanism.
/// AlarmManager was removed due to android_alarm_manager_plus incompatibility
/// with Android 16 (SDK 36) — RebootBroadcastReceiver crash.
class TrackingWatchdogService {
  TrackingWatchdogService._();

  static const String _workManagerTaskName = 'gps_tracking_watchdog';
  static const String _workManagerUniqueId = 'ca.trilogis.gpstracker.watchdog';

  /// SharedPreferences key for watchdog breadcrumbs.
  /// Written by watchdog isolates so the main app can read & sync them later.
  static const String _prefsName = 'watchdog_log';

  // ── Initialization (call once at app startup) ──

  /// Initialize WorkManager watchdog engine.
  /// Must be called once in main() before any start/stop calls.
  /// Failures are caught so watchdog issues never block app startup.
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;

    try {
      await Workmanager().initialize(
        _workManagerCallbackDispatcher,
        isInDebugMode: false,
      );

      // Register WorkManager periodic task (always active, very low cost).
      // If shift_id is null the callback is a no-op.
      await Workmanager().registerPeriodicTask(
        _workManagerUniqueId,
        _workManagerTaskName,
        frequency: const Duration(minutes: 5),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
        ),
      );
    } catch (e) {
      debugPrint('[Watchdog] WorkManager init failed: $e');
    }
  }

  // ── Shared watchdog logic ──

  /// Core watchdog check: if shift is active but service is dead, restart it.
  /// Returns true if a restart was attempted.
  ///
  /// May run in a fresh isolate (WorkManager callback), so we ensure Flutter
  /// bindings and foreground task notification channels are ready.
  /// All steps are logged to SharedPreferences so the main app can read them
  /// later — DiagnosticLogger is not available in watchdog isolates.
  static Future<bool> _checkAndRestart(String source) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await BackgroundTrackingService.initialize();

      final shiftId =
          await FlutterForegroundTask.getData<String>(key: 'shift_id');
      if (shiftId == null || shiftId.isEmpty) {
        await _writeLog(source, 'no_shift', null);
        return false;
      }

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        await _writeLog(source, 'service_alive', shiftId);
        return false;
      }

      // Service is dead with an active shift — restart
      final employeeId =
          await FlutterForegroundTask.getData<String>(key: 'employee_id');
      if (employeeId == null || employeeId.isEmpty) {
        await _writeLog(source, 'no_employee_id', shiftId);
        return false;
      }

      await _writeLog(source, 'restarting', shiftId);

      await FlutterForegroundTask.startService(
        notificationTitle: 'Suivi de position actif',
        notificationText: 'Reprise automatique du suivi',
        callback: startCallback,
      );

      await _writeLog(source, 'restart_success', shiftId);

      // Also try DiagnosticLogger (may not be initialized in isolate)
      _tryLog(source, shiftId);
      return true;
    } catch (e) {
      // Log the error instead of failing silently
      try {
        await _writeLog(source, 'error: $e', null);
      } catch (_) {}
      return false;
    }
  }

  /// Write a breadcrumb log entry to SharedPreferences.
  /// Uses flutter_foreground_task's data store (SharedPreferences-based),
  /// which works in any isolate without extra initialization.
  static Future<void> _writeLog(
    String source,
    String outcome,
    String? shiftId,
  ) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final entry = '$now|$source|$outcome|${shiftId ?? ''}';

      // Read existing log (keep last 20 entries to avoid bloat)
      final existing =
          await FlutterForegroundTask.getData<String>(key: _prefsName) ?? '';
      final lines = existing.isEmpty ? <String>[] : existing.split('\n');
      lines.add(entry);
      // Keep only last 20 entries
      while (lines.length > 20) {
        lines.removeAt(0);
      }

      await FlutterForegroundTask.saveData(
        key: _prefsName,
        value: lines.join('\n'),
      );
    } catch (_) {
      // Best-effort — never crash the watchdog for logging
    }
  }

  /// Read and clear the watchdog log. Called by the main app on resume
  /// to sync breadcrumbs into DiagnosticLogger.
  static Future<List<String>> consumeLog() async {
    try {
      final raw =
          await FlutterForegroundTask.getData<String>(key: _prefsName) ?? '';
      if (raw.isEmpty) return [];

      // Clear after reading
      await FlutterForegroundTask.saveData(key: _prefsName, value: '');
      return raw.split('\n').where((l) => l.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static void _tryLog(String source, String shiftId) {
    try {
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.lifecycle(
          Severity.warn,
          'Watchdog: service dead, restarting ($source)',
          metadata: {'shift_id': shiftId},
        );
      }
    } catch (_) {
      // Logging is best-effort in watchdog context
    }
  }
}

// WorkManager callback must be a top-level function
@pragma('vm:entry-point')
void _workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == TrackingWatchdogService._workManagerTaskName) {
      await TrackingWatchdogService._checkAndRestart('workmanager');
    }
    return true;
  });
}
```

Key changes:
- Removed `android_alarm_manager_plus` import
- Removed `_alarmId` constant
- Removed `startAlarm()` and `stopAlarm()` methods
- Removed `_alarmCallback()` method
- Changed WorkManager frequency from 15 min to 5 min
- Changed `existingWorkPolicy` from `keep` to `replace` (to pick up the new 5-min interval)
- Updated class documentation

**Step 2: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/services/tracking_watchdog_service.dart`
Expected: No errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart
git commit -m "feat: remove android_alarm_manager_plus, promote WorkManager to 5-min primary watchdog"
```

---

### Task 2: Remove AlarmManager calls from BackgroundTrackingService

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

**Step 1: Remove `startAlarm()` call from `startTracking()`**

At line 183, remove:
```dart
          await TrackingWatchdogService.startAlarm();
```

**Step 2: Remove `stopAlarm()` call from `stopTracking()`**

At line 219, remove:
```dart
    await TrackingWatchdogService.stopAlarm();
```

**Step 3: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/services/background_tracking_service.dart`
Expected: No errors

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/background_tracking_service.dart
git commit -m "refactor: remove AlarmManager start/stop calls from BackgroundTrackingService"
```

---

### Task 3: Remove `android_alarm_manager_plus` from pubspec.yaml and proguard

**Files:**
- Modify: `gps_tracker/pubspec.yaml`
- Modify: `gps_tracker/android/app/proguard-rules.pro`

**Step 1: Remove from pubspec.yaml**

At line 11, remove:
```yaml
  android_alarm_manager_plus: ^4.0.0
```

**Step 2: Remove from proguard-rules.pro**

At lines 41-42, remove:
```proguard
# Keep Android Alarm Manager (watchdog primary mechanism)
-keep class dev.fluttercommunity.plus.androidalarmmanager.** { *; }
```

**Step 3: Run `flutter pub get`**

Run: `cd gps_tracker && flutter pub get`
Expected: No errors

**Step 4: Run analyzer**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors related to alarm_manager

**Step 5: Commit**

```bash
git add gps_tracker/pubspec.yaml gps_tracker/pubspec.lock gps_tracker/android/app/proguard-rules.pro
git commit -m "chore: remove android_alarm_manager_plus dependency and proguard rule"
```

---

### Task 4: Clean up AndroidManifest.xml (if needed)

**Files:**
- Check: `gps_tracker/android/app/src/main/AndroidManifest.xml`

**Step 1: Verify RECEIVE_BOOT_COMPLETED and WAKE_LOCK are still needed**

Both permissions are still required by:
- `flutter_foreground_task` (autoRunOnBoot needs RECEIVE_BOOT_COMPLETED)
- `flutter_foreground_task` (allowWakeLock needs WAKE_LOCK)
- `TrackingBootReceiver.kt` (BOOT_COMPLETED intent filter)

**No changes needed** — these permissions are NOT alarm-manager-specific.

**Step 2: Commit (skip if no changes)**

No commit needed for this task.

---

### Task 5: Full build verification and deploy

**Step 1: Run full analyzer**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

**Step 2: Run tests**

Run: `cd gps_tracker && flutter test`
Expected: All existing tests pass

**Step 3: Deploy**

Run: `/deploy`

This is a critical fix affecting 100% of Android 16 devices — deploy immediately.
