# Foreground Service Resilience — Design Document

**Date**: 2026-02-26
**Feature**: 020-foreground-service-resilience
**Problem**: Android 14-16 kills the GPS tracking foreground service despite battery optimization exemption, causing GPS gaps of 45+ minutes.

## Context

Two employees (Android 14 SDK 34, Android 16 SDK 36) have their tracking process killed entirely — zero diagnostic logs after the kill point. QuickBooks Time on the same devices still gets location, suggesting our app lacks the layered restart mechanisms that established apps use.

### Why Battery Optimization Exemption Isn't Enough

The exemption only protects against standard Android Doze mode. Three additional layers can kill the service:

1. **OEM battery managers** (Samsung SmartManager, Xiaomi MIUI, etc.) — independent of AOSP exemption
2. **Android 14+ FGS restrictions** — tighter timeout enforcement, background start limits
3. **Memory pressure** — OS kills FGS when RAM drops below ~15-20%, ignoring `stopWithTask="false"`

### Current State

The app already has:
- Foreground service with `foregroundServiceType="location"` + `stopWithTask="false"`
- Battery optimization exemption check + request (blocks clock-in if missing)
- OEM-specific settings guidance (Samsung, Xiaomi, Huawei, Honor, OnePlus, Oppo, Realme)
- GPS self-healing (background handler exponential backoff + main isolate `recoverStream`)
- Health check on app resume (`_checkForegroundServiceHealth`)
- App Standby Bucket monitoring
- Battery exemption regression detection (`hasLostBatteryOptimizationExemption`)
- Battery Health Screen with "Corriger" buttons

### What's Missing

No mechanism to detect and restart the service when the app is **not in the foreground**. Once the process is killed while backgrounded, tracking stays dead until the user manually opens the app.

## Design

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                    App Process                   │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │ Foreground    │    │ TrackingProvider        │  │
│  │ Service (FGS) │◄──│ (health check on resume)│  │
│  └──────────────┘    └────────────────────────┘  │
│         ▲                                        │
└─────────┼────────────────────────────────────────┘
          │ restart if dead
          │
┌─────────┴────────────────────────────────────────┐
│              Independent Watchdogs               │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │ AlarmManager  │    │ WorkManager             │  │
│  │ (every 5 min) │    │ (every 15 min, backup)  │  │
│  │ PRIMARY check │    │ SECONDARY check         │  │
│  └──────────────┘    └────────────────────────┘  │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │ BootReceiver  │    │ Connectivity listener   │  │
│  │ (boot/update) │    │ (network change)        │  │
│  └──────────────┘    └────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### Component 1: AlarmManager Watchdog (Primary, 5 min)

**New dependency**: `android_alarm_manager_plus: ^4.0.0`

**Behavior**:
- Started when clock-in succeeds, cancelled on clock-out
- Every 5 min (inexact, `allowWhileIdle: true`): checks `FlutterForegroundTask.isRunningService`
- If service is dead AND `shift_id` exists in FlutterForegroundTask storage → restart service
- Logs restart attempt via DiagnosticLogger
- On Android 14+: uses `setAndAllowWhileIdle` (no exact alarm permission needed)

**New file**: `gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart`

```dart
class TrackingWatchdogService {
  static const int _alarmId = 42;

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.periodic(
      const Duration(minutes: 5),
      _alarmId,
      _watchdogCallback,
      exact: false,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
    );
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.cancel(_alarmId);
  }

  @pragma('vm:entry-point')
  static Future<void> _watchdogCallback() async {
    final shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    if (shiftId == null) return; // No active shift

    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) return; // Service alive, nothing to do

    // Service dead with active shift → restart
    final employeeId = await FlutterForegroundTask.getData<String>(key: 'employee_id');
    if (employeeId == null) return;

    await FlutterForegroundTask.startService(
      notificationTitle: 'Suivi de position actif',
      notificationText: 'Reprise automatique du suivi',
      callback: startCallback,
    );
    // Log via fire-and-forget diagnostic
  }
}
```

### Component 2: WorkManager Watchdog (Backup, 15 min)

**New dependency**: `workmanager: ^0.5.2`

**Behavior**:
- Registered once at app startup (always active, very low battery cost)
- Every 15 min: same check as AlarmManager — is service running? is there an active shift?
- Acts as backup if AlarmManager was killed or delayed by Doze
- Constraints: no network required, no charging required, no idle required

**Integration**: Added to `TrackingWatchdogService` alongside AlarmManager.

### Component 3: BroadcastReceiver (Boot/Update)

**New file**: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingBootReceiver.kt`

**Behavior**:
- Listens for `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`
- Checks SharedPreferences for active shift ID
- If active shift exists → start foreground service
- Already partially handled by `autoRunOnBoot: true`, but explicit receiver is more reliable on OEM ROMs

**Manifest entry**:
```xml
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

### Component 4: Connectivity Change Listener

**No new dependency** — uses existing `connectivity_plus: ^6.0.0`

**Behavior**:
- When connectivity changes from `none` → any connected state:
  1. Verify foreground service is alive
  2. If dead + active shift → attempt restart
  3. Trigger pending data sync

**Integration**: Added to `TrackingProvider._init()` alongside existing listeners.

## Lifecycle

```
Clock-In:
  1. Start foreground service (existing)
  2. Start AlarmManager watchdog (5 min periodic)
  3. WorkManager already running (registered at app start)

During Shift:
  - AlarmManager fires every ~5 min → checks service alive
  - WorkManager fires every ~15 min → backup check
  - App resume → existing health check
  - Connectivity change → verify service alive

Service Killed by Android:
  - Next AlarmManager tick (≤5 min) → detects death → restarts
  - If AlarmManager also killed → WorkManager tick (≤15 min) → restarts
  - If user opens app → existing resume check → restarts immediately

Clock-Out:
  1. Stop foreground service (existing)
  2. Cancel AlarmManager watchdog
  3. Clear shift_id from storage (WorkManager sees no shift → no-op)

Boot/App Update:
  - BroadcastReceiver fires → checks for active shift → restarts if needed
```

## Diagnostic Logging

All watchdog actions logged with category `lifecycle`, severity `warn`:
- `"Watchdog: service dead, restarting (alarm)"` — AlarmManager detected death
- `"Watchdog: service dead, restarting (workmanager)"` — WorkManager detected death
- `"Watchdog: service dead, restarting (boot)"` — BroadcastReceiver restart
- `"Watchdog: service dead, restarting (connectivity)"` — Network change restart
- `"Watchdog: service alive, no action"` — periodic check passed (debug only)

## New Dependencies

```yaml
# pubspec.yaml additions
android_alarm_manager_plus: ^4.0.0
workmanager: ^0.5.2
```

## Files to Create/Modify

### New Files
1. `gps_tracker/lib/features/tracking/services/tracking_watchdog_service.dart` — AlarmManager + WorkManager logic
2. `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingBootReceiver.kt` — BroadcastReceiver

### Modified Files
1. `gps_tracker/pubspec.yaml` — add 2 dependencies
2. `gps_tracker/lib/main.dart` — initialize AlarmManager + WorkManager
3. `gps_tracker/android/app/src/main/AndroidManifest.xml` — register BroadcastReceiver
4. `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` — call watchdog start/stop in startTracking/stopTracking
5. `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — add connectivity listener for service health check

## Constraints

- AlarmManager `exact: false` — no `SCHEDULE_EXACT_ALARM` permission needed (Android 14+ compatible)
- WorkManager 15 min minimum — Android API hard limit, cannot go lower
- BroadcastReceiver on Android 12+ — manifest receivers limited but `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED` still work
- Watchdog restart from background may fail on Android 15+ if app is in RESTRICTED standby bucket — this is acceptable (fail-open)
- All watchdog actions are no-ops if no `shift_id` in storage (no false restarts)

## Testing Plan

1. Start a shift, force-kill the app via `adb shell am force-stop ca.trilogis.gpstracker`
2. Wait 5 minutes → verify AlarmManager restarts the service (check diagnostic logs)
3. Force-kill again, disable AlarmManager → wait 15 minutes → verify WorkManager restarts
4. Reboot device with active shift → verify BroadcastReceiver restarts
5. Toggle airplane mode on/off with active shift → verify connectivity listener checks service
6. Clock out → verify AlarmManager is cancelled (no phantom restarts)
7. Test on Android 14 and Android 16 devices specifically
