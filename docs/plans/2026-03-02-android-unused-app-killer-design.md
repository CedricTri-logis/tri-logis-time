# Android Unused App Killer Survival — Design

**Date:** 2026-03-02
**Status:** Approved
**Problem:** Samsung S9 (and similar) kills the GPS foreground service when workers switch to another app or turn the screen off during an active shift, causing GPS data loss of up to 5 minutes.

## Root Cause

The current foreground service uses `NotificationChannelImportance.DEFAULT`. Samsung One UI (including S9 / One UI 2.x) uses notification importance as a signal for its background killer — DEFAULT importance notifications are treated as killable. Combined with workers skipping or not completing the one-time OEM battery setup dialog, the service is vulnerable even when battery optimization exemption has been requested.

The article's 90-day hibernation APIs (`PackageManagerCompat`) are largely irrelevant to the immediate S9 problem but are added as future-proofing for Android 11+ workers.

## Architecture

Three coordinated layers:

```
Layer A: Foreground Service Hardening
  notification importance: DEFAULT → HIGH (new channel ID required)
  → Prevents Samsung from classifying the service as killable

Layer B: Mandatory Setup Flow
  B1: PackageManagerCompat.getUnusedAppRestrictionsStatus() (Android 11+)
  B2: OEM guide dialog becomes mandatory/blocking, re-verifies on return
  → Ensures workers actually complete battery settings

Layer C: Native 60s AlarmManager Rescue Watchdog
  TrackingRescueReceiver.kt — BroadcastReceiver, chaining exact alarms
  → Reduces gap from 5 min (WorkManager) to ~60s on service death
```

WorkManager 5-minute watchdog remains as safety net.

---

## Layer A: Notification Importance Upgrade

**File:** `lib/features/tracking/services/background_tracking_service.dart`

| Field | Before | After |
|---|---|---|
| `channelId` | `'gps_tracking_channel'` | `'gps_tracking_channel_v2'` |
| `channelImportance` | `NotificationChannelImportance.DEFAULT` | `NotificationChannelImportance.HIGH` |
| `priority` | `NotificationPriority.DEFAULT` | `NotificationPriority.HIGH` |

**Why new channel ID:** Android caches channel importance per ID. Changing importance on an existing ID is silently ignored by the OS. A new channel ID forces Android to create a fresh channel with the new importance level.

**Why HIGH not MAX:** MAX triggers heads-up banners on every update, which would be disruptive. HIGH gives persistent status bar + lock screen visibility — sufficient to signal importance to Samsung's killer.

**Side effect:** Old `gps_tracking_channel` becomes an orphaned channel in app notification settings. Harmless. No user action needed.

---

## Layer B: Mandatory Setup Flow

### B1 — PackageManagerCompat Integration (Android 11+)

Add two new calls to the existing `gps_tracker/device_manufacturer` method channel in `MainActivity.kt`:

- `getUnusedAppRestrictionsStatus()` → returns int constant
  - `FEATURE_NOT_AVAILABLE` (Android ≤10, e.g. S9) → no action
  - `DISABLED` → restrictions already disabled, no action
  - `API_30`, `API_30_BACKPORT`, `API_31` → restrictions active, prompt user
- `openManageUnusedAppRestrictionsSettings()` → calls `IntentCompat.createManageUnusedAppRestrictionsIntent()`

Wire into `AndroidBatteryHealthService` in Dart. Add `unusedAppRestrictionsOk` field to `PermissionGuardState`. Block clock-in if status is `API_30`, `API_30_BACKPORT`, or `API_31`.

**Note:** Has zero effect on S9 (Android 10, returns `FEATURE_NOT_AVAILABLE`). Future-proofs for Android 11+ devices.

**Dependency:** Verify `androidx.core:core-ktx >= 1.7.0` is in `android/app/build.gradle`. If using coroutines version, also add `androidx.concurrent:concurrent-futures-ktx:1.1.0`.

### B2 — Mandatory OEM Guide Dialog

**Current behavior:** `oem_setup_completed` flag is set once on first acknowledge → dialog never shown again, even if settings were reset by OEM/OS update.

**New behavior:**
1. On every clock-in attempt, check actual state (battery optimization + unused app restrictions)
2. If state is bad → show OEM guide dialog as non-skippable modal
3. "I've completed the steps" confirm button only enabled after user has opened the settings page (tracked via `ActivityResultLauncher` callback in native layer, exposed as a completion flag)
4. After user returns from OEM settings, re-check state and show ✅/❌ before allowing clock-in

**Files affected:**
- `lib/features/tracking/widgets/oem_battery_guide_dialog.dart` — remove one-time flag gate, add mandatory mode
- `lib/features/tracking/providers/permission_guard_provider.dart` — add `unusedAppRestrictionsOk` check
- `lib/features/tracking/models/permission_guard_state.dart` — add field

---

## Layer C: Native 60s AlarmManager Rescue Watchdog

### New file: `TrackingRescueReceiver.kt`

```
android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt
```

A `BroadcastReceiver` that:
1. Reads `shift_id` from `flutter_foreground_task`'s SharedPreferences key
2. If `shift_id` present → calls `startForegroundService(FFT service intent)` unconditionally
   - Harmless if service is already running (just calls `onStartCommand()` again)
   - Restarts service if it was killed
3. Schedules next alarm via `AlarmManager.setExactAndAllowWhileIdle(T+60s)`

### Changes to `MainActivity.kt`

Add to `gps_tracker/device_manufacturer` method channel:
- `startRescueAlarms(shiftId: String)` — schedules first exact alarm for T+60s
- `stopRescueAlarms()` — cancels pending alarm via `AlarmManager.cancel()`

### Changes to `AndroidManifest.xml`

```xml
<!-- New receiver -->
<receiver
    android:name=".TrackingRescueReceiver"
    android:exported="false" />

<!-- New permissions -->
<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
```

`USE_EXACT_ALARM` (Android 13+) is auto-granted for apps whose core use includes location tracking — no user action needed. On Android 12 where `SCHEDULE_EXACT_ALARM` would be needed, we check `canScheduleExactAlarms()` and fall back to `setAndAllowWhileIdle()` (inexact). WorkManager 5-min watchdog covers the gap.

### Changes to `background_tracking_service.dart`

- After `FlutterForegroundTask.startService()` → call native `startRescueAlarms(shiftId)`
- After `FlutterForegroundTask.stopService()` → call native `stopRescueAlarms()`
- Add to `android_battery_health_service.dart`: `startRescueAlarms()` / `stopRescueAlarms()` methods

---

## Data Flow During Shift

```
Clock-in
  → startTracking()
    → FlutterForegroundTask.startService()     [foreground service, HIGH importance]
    → startRescueAlarms(shiftId)              [60s AlarmManager chain starts]
    → WorkManager watchdog [5-min, already running]

Screen off / switch apps
  → [Samsung kills FFT service]
  → ~60s later: TrackingRescueReceiver fires
    → reads shift_id from SharedPrefs
    → startForegroundService(FFT)             [service restarted]
    → schedules next alarm T+60s

Clock-out
  → stopTracking()
    → FlutterForegroundTask.stopService()
    → stopRescueAlarms()                      [alarm chain stopped]
    → shift_id cleared from SharedPrefs
```

---

## Error Handling

- **B1 dependency missing:** `PackageManagerCompat` not available → catch `Exception`, return `FEATURE_NOT_AVAILABLE`, no crash
- **C alarm not schedulable (Android 12 without permission):** `canScheduleExactAlarms()` check before `setExactAndAllowWhileIdle()`, fall back to `setAndAllowWhileIdle()`
- **C receiver fires after clock-out:** `shift_id` will be empty in SharedPrefs → receiver does nothing, does NOT reschedule next alarm → chain stops naturally
- **Old notification channel:** remains in system settings as orphan, silently ignored

---

## Testing

- **Layer A:** Install on S9 → switch apps → check if foreground notification remains in status bar
- **Layer B:** Fresh install → clock-in → verify OEM dialog appears if battery optimization enabled
- **Layer B:** On Android 11+ test device → set app to hibernatable → verify clock-in blocked
- **Layer C:** Force-stop the FFT service via `adb shell am kill ca.trilogis.gpstracker` → verify restart within 90s
- **Layer C clock-out:** Clock out → wait 2 min → verify no service restart (alarm chain stopped)
