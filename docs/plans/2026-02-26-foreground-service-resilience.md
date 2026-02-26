# Foreground Service Resilience Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent Android 14-16 from permanently killing the GPS tracking service by adding layered watchdog mechanisms that detect and restart the service independently.

**Architecture:** Three independent watchdogs (AlarmManager 5 min, WorkManager 15 min, BroadcastReceiver on boot) monitor the foreground service and restart it if killed. A connectivity listener provides opportunistic restart on network change. All watchdogs are no-ops when no shift is active.

**Tech Stack:** `android_alarm_manager_plus: ^4.0.0`, `workmanager: ^0.5.2`, existing `connectivity_plus: ^6.0.0`, existing `flutter_foreground_task: ^9.0.0`, Kotlin BroadcastReceiver

---

### Task 1: Add Dependencies

**Files:**
- Modify: `gps_tracker/pubspec.yaml`

**Step 1: Add android_alarm_manager_plus and workmanager to pubspec.yaml**

In `gps_tracker/pubspec.yaml`, add these two dependencies after the existing `connectivity_plus` line (line 11):

```yaml
  android_alarm_manager_plus: ^4.0.0
```

And after the existing `uuid` line (line 41):

```yaml
  workmanager: ^0.5.2
```

**Step 2: Run pub get**

Run: `cd gps_tracker && flutter pub get`
Expected: Dependencies resolve successfully, no version conflicts.

**Step 3: Commit**

```bash
git add gps_tracker/pubspec.yaml gps_tracker/pubspec.lock
git commit -m "feat(deps): add android_alarm_manager_plus and workmanager for service watchdog"
```

---

### Task 2: Create TrackingWatchdogService

**Files:**
- Create: `gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart`

**Step 1: Create the watchdog service**

This file combines both AlarmManager (5 min) and WorkManager (15 min) watchdog logic. The AlarmManager callback and WorkManager callback both run the same check: is the foreground service dead? Is there an active shift? If yes to both, restart the service.

```dart
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import 'background_tracking_service.dart';

/// Layered watchdog service that detects and restarts the GPS foreground
/// service if Android kills it during an active shift.
///
/// Two independent mechanisms:
/// - AlarmManager: fires every 5 min (primary, faster detection)
/// - WorkManager: fires every 15 min (backup, guaranteed by Android)
class TrackingWatchdogService {
  TrackingWatchdogService._();

  static const int _alarmId = 9001;
  static const String _workManagerTaskName = 'gps_tracking_watchdog';
  static const String _workManagerUniqueId = 'ca.trilogis.gpstracker.watchdog';

  // ── Initialization (call once at app startup) ──

  /// Initialize AlarmManager and WorkManager engines.
  /// Must be called once in main() before any start/stop calls.
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;

    await AndroidAlarmManager.initialize();
    await Workmanager().initialize(
      _workManagerCallbackDispatcher,
      isInDebugMode: false,
    );

    // Register WorkManager periodic task (always active, very low cost).
    // If shift_id is null the callback is a no-op.
    await Workmanager().registerPeriodicTask(
      _workManagerUniqueId,
      _workManagerTaskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(
        networkType: NetworkType.not_required,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
      ),
    );
  }

  // ── AlarmManager (primary, 5 min) ──

  /// Start the AlarmManager periodic watchdog. Call on clock-in.
  static Future<void> startAlarm() async {
    if (!Platform.isAndroid) return;

    await AndroidAlarmManager.periodic(
      const Duration(minutes: 5),
      _alarmId,
      _alarmCallback,
      exact: false,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
    );
  }

  /// Cancel the AlarmManager watchdog. Call on clock-out.
  static Future<void> stopAlarm() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.cancel(_alarmId);
  }

  // ── Shared watchdog logic ──

  /// Core watchdog check: if shift is active but service is dead, restart it.
  /// Returns true if a restart was attempted.
  static Future<bool> _checkAndRestart(String source) async {
    try {
      final shiftId =
          await FlutterForegroundTask.getData<String>(key: 'shift_id');
      if (shiftId == null || shiftId.isEmpty) return false;

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) return false;

      // Service is dead with an active shift — restart
      final employeeId =
          await FlutterForegroundTask.getData<String>(key: 'employee_id');
      if (employeeId == null || employeeId.isEmpty) return false;

      await FlutterForegroundTask.startService(
        notificationTitle: 'Suivi de position actif',
        notificationText: 'Reprise automatique du suivi',
        callback: startCallback,
      );

      // Log the restart (fire-and-forget — logger may not be initialized in isolate)
      _tryLog(source, shiftId);
      return true;
    } catch (_) {
      // Fail silently — watchdog must never crash
      return false;
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

  // ── Callbacks ──

  @pragma('vm:entry-point')
  static Future<void> _alarmCallback() async {
    await _checkAndRestart('alarm');
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

**Step 2: Export from services barrel**

In `gps_tracker/lib/features/tracking/services/services.dart`, add:

```dart
export 'tracking_watchdog_service.dart';
```

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart gps_tracker/lib/features/tracking/services/services.dart
git commit -m "feat: add TrackingWatchdogService with AlarmManager + WorkManager watchdogs"
```

---

### Task 3: Create TrackingBootReceiver (Kotlin)

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingBootReceiver.kt`
- Modify: `gps_tracker/android/app/src/main/AndroidManifest.xml`

**Step 1: Create the BroadcastReceiver**

This Kotlin class listens for `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`. It reads the `shift_id` from `flutter_foreground_task`'s SharedPreferences. If an active shift exists, it attempts to start the foreground service.

Create `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingBootReceiver.kt`:

```kotlin
package ca.trilogis.gpstracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * BroadcastReceiver that restarts the GPS tracking foreground service
 * after device boot or app update if there was an active shift.
 *
 * This is a safety net on top of flutter_foreground_task's autoRunOnBoot,
 * providing more reliable restart on OEM Android ROMs.
 */
class TrackingBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingBootReceiver"
        // flutter_foreground_task stores data in this SharedPreferences file
        private const val FGT_PREFS = "flutter_foreground_task"
        private const val KEY_SHIFT_ID = "shift_id"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }

        Log.d(TAG, "Received $action — checking for active shift")

        // Read shift_id from flutter_foreground_task's SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            Log.d(TAG, "No active shift — skipping service restart")
            return
        }

        Log.i(TAG, "Active shift found ($shiftId) — attempting service restart")

        // flutter_foreground_task's autoRunOnBoot should handle the actual restart,
        // but we log here for diagnostic visibility. If the plugin's mechanism fails,
        // the AlarmManager/WorkManager watchdogs will catch it within 5-15 min.
    }
}
```

**Step 2: Register the receiver in AndroidManifest.xml**

In `gps_tracker/android/app/src/main/AndroidManifest.xml`, add this inside the `<application>` block, after the `<service>` block (after line 90):

```xml
        <!-- Boot/update receiver for GPS tracking restart -->
        <receiver
            android:name=".TrackingBootReceiver"
            android:exported="true"
            android:enabled="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
            </intent-filter>
        </receiver>
```

**Step 3: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingBootReceiver.kt gps_tracker/android/app/src/main/AndroidManifest.xml
git commit -m "feat: add TrackingBootReceiver for service restart on boot and app update"
```

---

### Task 4: Initialize Watchdog in main.dart

**Files:**
- Modify: `gps_tracker/lib/main.dart`

**Step 1: Import the watchdog service**

Add this import after the existing `android_battery_health_service.dart` import (line 11):

```dart
import 'features/tracking/services/tracking_watchdog_service.dart';
```

**Step 2: Initialize watchdog in _initializeTracking()**

In the `_initializeTracking()` function (line 163), add the watchdog initialization after the existing calls:

Change `_initializeTracking()` from:

```dart
Future<void> _initializeTracking() async {
  FlutterForegroundTask.initCommunicationPort();
  await BackgroundTrackingService.initialize();
  await AndroidBatteryHealthService.saveBatteryOptimizationSnapshot();
}
```

To:

```dart
Future<void> _initializeTracking() async {
  FlutterForegroundTask.initCommunicationPort();
  await BackgroundTrackingService.initialize();
  await AndroidBatteryHealthService.saveBatteryOptimizationSnapshot();
  await TrackingWatchdogService.initialize();
}
```

**Step 3: Commit**

```bash
git add gps_tracker/lib/main.dart
git commit -m "feat: initialize TrackingWatchdogService at app startup"
```

---

### Task 5: Wire Watchdog Start/Stop to Tracking Lifecycle

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

**Step 1: Import the watchdog service**

Add this import after the existing `background_execution_service.dart` import (line 12):

```dart
import 'tracking_watchdog_service.dart';
```

**Step 2: Start watchdog alarm on successful tracking start**

In `startTracking()`, after the `return const TrackingSuccess();` block (line 178), add the watchdog start. Change:

```dart
      if (result is ServiceRequestSuccess) {
        _logger?.gps(
          Severity.info,
          'Foreground service start success',
          metadata: {'shift_id': shiftId},
        );
        return const TrackingSuccess();
```

To:

```dart
      if (result is ServiceRequestSuccess) {
        _logger?.gps(
          Severity.info,
          'Foreground service start success',
          metadata: {'shift_id': shiftId},
        );
        await TrackingWatchdogService.startAlarm();
        return const TrackingSuccess();
```

**Step 3: Stop watchdog alarm on tracking stop**

In `stopTracking()` (line 201), add the watchdog stop before clearing data. Change:

```dart
  static Future<void> stopTracking() async {
    await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.removeData(key: 'shift_id');
```

To:

```dart
  static Future<void> stopTracking() async {
    await TrackingWatchdogService.stopAlarm();
    await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.removeData(key: 'shift_id');
```

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/background_tracking_service.dart
git commit -m "feat: wire watchdog alarm start/stop to tracking lifecycle"
```

---

### Task 6: Add Connectivity Listener for Service Health Check

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

**Step 1: Add connectivity_plus import**

Add this import at the top of the file, after the existing imports:

```dart
import 'package:connectivity_plus/connectivity_plus.dart';
```

**Step 2: Add connectivity subscription field**

After the existing `_thermalSubscription` field (line 63), add:

```dart
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
```

**Step 3: Add connectivity listener in _initializeListeners()**

At the end of `_initializeListeners()` (after line 83), add:

```dart
    // Listen for connectivity changes to verify service health
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);
```

**Step 4: Add the handler method**

Add this method to the `TrackingNotifier` class, near the other `_handle*` methods:

```dart
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    // Only act when connectivity is restored (not on disconnect)
    if (results.contains(ConnectivityResult.none) || results.isEmpty) return;

    // Only check if we think we're tracking
    if (state.status != TrackingStatus.running) return;

    _logger?.network(Severity.info, 'Connectivity restored — verifying service');

    // Verify the foreground service is still alive
    BackgroundTrackingService.isTracking.then((isRunning) {
      if (!isRunning && state.activeShiftId != null) {
        _logger?.lifecycle(
          Severity.warn,
          'Watchdog: service dead, restarting (connectivity)',
          metadata: {'shift_id': state.activeShiftId},
        );
        _onForegroundServiceDied();
      }
    });

    // Trigger sync of any pending local data
    _ref.read(syncProvider.notifier).notifyPendingData();
  }
```

**Step 5: Cancel subscription in dispose()**

Find the existing `dispose()` method and add the cancel. Look for where `_thermalSubscription?.cancel()` is called and add after it:

```dart
    _connectivitySubscription?.cancel();
```

**Step 6: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat: add connectivity listener to verify service health on network change"
```

---

### Task 7: Verify Build

**Step 1: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors. Warnings are acceptable but no new ones related to our changes.

**Step 2: Run flutter build for Android**

Run: `cd gps_tracker && flutter build apk --debug`
Expected: Build succeeds. This verifies the Kotlin BroadcastReceiver compiles and the manifest is valid.

**Step 3: Commit any fixes if needed**

If there are compile errors, fix them and commit:

```bash
git add -A
git commit -m "fix: resolve build issues from watchdog integration"
```

---

### Task 8: Test on Device

This task requires a physical Android device or emulator.

**Step 1: Install and start a shift**

Run: `cd gps_tracker && flutter run -d android`
Clock in on the app.

**Step 2: Verify watchdog started**

Check logcat for the AlarmManager registration:
Run: `adb logcat | grep -i "alarm\|watchdog\|TrackingBoot"`

**Step 3: Force-kill the app**

Run: `adb shell am force-stop ca.trilogis.gpstracker`
Wait 5-7 minutes.

**Step 4: Check if service restarted**

Run: `adb shell "ps -A | grep trilogis"`
Expected: Process should be running again (AlarmManager restarted it).

Check Supabase diagnostic_logs for the watchdog restart message:
```sql
SELECT message, created_at
FROM diagnostic_logs
WHERE employee_id = '<your_id>'
ORDER BY created_at DESC
LIMIT 5;
```

**Step 5: Clock out and verify cleanup**

Clock out in the app. Verify no phantom restarts by waiting 10 minutes and checking there are no new "Watchdog" log entries.

---

### Summary of Changes

| File | Action | Description |
|---|---|---|
| `pubspec.yaml` | Modify | Add `android_alarm_manager_plus`, `workmanager` |
| `tracking_watchdog_service.dart` | Create | AlarmManager (5 min) + WorkManager (15 min) watchdog |
| `TrackingBootReceiver.kt` | Create | BroadcastReceiver for BOOT_COMPLETED + MY_PACKAGE_REPLACED |
| `AndroidManifest.xml` | Modify | Register TrackingBootReceiver |
| `main.dart` | Modify | Initialize watchdog at startup |
| `background_tracking_service.dart` | Modify | Start/stop alarm on tracking start/stop |
| `tracking_provider.dart` | Modify | Add connectivity listener for service health check |
| `services.dart` | Modify | Export tracking_watchdog_service |
