# Remove android_alarm_manager_plus — Android 16 Compatibility Fix

## Problem

`android_alarm_manager_plus` v4.0.0 throws `RebootBroadcastReceiver does not exist in ca.trilogis.gpstracker` on **every clock-in** for all Android 16 (SDK 36) devices. The exception is caught but:

1. Corrupts internal alarm state on some devices
2. Combined with connectivity issues, causes the foreground GPS service to die permanently
3. Requires app reinstall to recover — simple restart doesn't fix it
4. Affects 4/4 Android 16 employees in production (100% hit rate)

## Root Cause

`android_alarm_manager_plus` tries to enable a `RebootBroadcastReceiver` component that doesn't exist in the app package on Android 16. This is a known incompatibility between the plugin and SDK 36's stricter package component validation.

## Solution

**Remove `android_alarm_manager_plus` entirely.** It's redundant — `workmanager` already provides the same watchdog functionality as a backup. Reduce WorkManager's interval from 15min to 5min to compensate.

## Architecture

The tracking watchdog has 3 independent layers:

| Layer | Current | After Fix |
|-------|---------|-----------|
| AlarmManager (5 min) | `android_alarm_manager_plus` | **REMOVED** |
| WorkManager (15 min) | `workmanager` | WorkManager (5 min) |
| App resume check | `didChangeAppLifecycleState` | Unchanged |

Removing AlarmManager leaves 2 layers, with WorkManager promoted to primary (5 min instead of 15 min). WorkManager is actually more reliable than AlarmManager on modern Android because it's guaranteed by the system scheduler and survives reboots natively.

## Components

### 1. pubspec.yaml
- Remove `android_alarm_manager_plus: ^4.0.0`

### 2. tracking_watchdog_service.dart
- Remove all `AndroidAlarmManager` imports and calls
- Remove `startAlarm()` / `stopAlarm()` methods
- Change WorkManager interval from 15min to 5min
- Remove AlarmManager-specific initialization
- Keep WorkManager and SharedPreferences-based breadcrumb logging

### 3. background_tracking_service.dart
- Remove calls to `TrackingWatchdogService.startAlarm()` / `stopAlarm()`
- Keep calls to `TrackingWatchdogService.initialize()` (now WorkManager-only)

### 4. main.dart
- Remove `android_alarm_manager_plus` import if present
- `TrackingWatchdogService.initialize()` call stays (now WorkManager-only)

### 5. AndroidManifest.xml
- Remove `RECEIVE_BOOT_COMPLETED` permission if only used by alarm manager (check if flutter_foreground_task also needs it — it does for autoRunOnBoot, so KEEP it)
- Remove `WAKE_LOCK` if only used by alarm manager (check — flutter_foreground_task also uses it, so KEEP it)

### 6. proguard-rules.pro
- Remove the `-keep class dev.fluttercommunity.plus.androidalarmmanager.**` rule

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| WorkManager throttled by Doze | Android guarantees ≥15min even in Doze; 5min runs as-is when not in Doze |
| app_standby_bucket UNKNOWN | WorkManager still fires — not affected by standby bucket the same way AlarmManager is |
| Reboot during active shift | flutter_foreground_task's autoRunOnBoot handles restart; WorkManager reschedules automatically |
| App update during active shift | flutter_foreground_task's autoRunOnMyPackageReplaced + TrackingBootReceiver handle this |

## What Does NOT Change

- flutter_foreground_task (actual GPS tracking service)
- GPS self-healing (exponential backoff recovery)
- App resume health check
- TrackingBootReceiver.kt (boot/update receiver)
- 30s tracking verification gate (just deployed in build 87)
- Diagnostic logging
