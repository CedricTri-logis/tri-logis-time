# Android Background Tracking Resilience — Combined Design

**Date:** 2026-03-02
**Status:** Approved
**Sources merged:** `2026-03-02-android-unused-app-killer-plan.md` + `2026-03-02-background-tracking-reliability.md`

## Problem

Samsung S9 (and similar OEM Android devices) kills the GPS foreground service when workers switch apps or lock the screen during an active shift. GPS data gaps of up to 5 minutes result. Compounding this: employees skip or ignore the one-time OEM battery setup dialog, and admins have no visibility into who has never completed it.

## Root Cause

1. Foreground service uses `NotificationChannelImportance.DEFAULT` — Samsung One UI treats this as killable.
2. `OemBatteryGuideDialog` had a one-time `oem_setup_completed` flag; once set, the dialog never appeared again, even after firmware regressions (Samsung silently removes apps from "Never Sleep" list).
3. No native watchdog with sub-5-minute recovery — WorkManager fires at 5-minute intervals.

## Architecture

Three hardening layers + five UX improvements:

```
Layer A: Foreground Service Hardening
  Notification importance: DEFAULT → HIGH (new channel ID required)
  → Prevents Samsung from classifying the service as killable

Layer B: Mandatory Setup Enforcement
  B1: PackageManagerCompat unused app restrictions (Android 11+)
      — Future-proofing only; no effect on Samsung S9 (Android 10)
  B2: OemBatteryGuideDialog rewrite — mandatory, state-verified
      — No "Plus tard" button; "C'est fait" verifies actual state
      — Server sync: marks battery_setup_completed_at on confirm

Layer UX: Visual Signals
  — Warning chip below clock button (Android)
  — Persistent regression banner during active shift
  — Shareable diagnostic report in BatteryHealthScreen

Layer C: Native 60s AlarmManager Rescue Watchdog
  TrackingRescueReceiver.kt — self-chaining BroadcastReceiver
  → Recovery gap: 5 min (WorkManager) → ~60s
```

WorkManager 5-minute watchdog remains as safety net.

---

## Conflict Resolution (vs. Source Plans)

| Source Plan | Task | Decision |
|---|---|---|
| BTR Task 1 | Add `forceOemGuide` param to `BatteryOptimizationDialog.show()` | **Dropped** — superseded by Layer B2 mandatory dialog (shows when state is bad regardless) |
| BTR Task 4 | `mark_battery_setup_completed` server RPC | **Merged into Layer B2** — `_syncCompletionToServer()` called from `_confirmDone()` |
| Migration number | BTR plan referenced `100_battery_setup_tracking.sql` | **Updated to `104`** — last applied is 103 |

**Downstream:** BTR Task 6 (regression banner)'s `_showRegressionBanner()` calls `BatteryOptimizationDialog.show(context)` without `forceOemGuide`. The OEM dialog auto-shows because battery is provably bad at that point (state check in B2 triggers it).

---

## Layer A: Notification Importance Upgrade

**File:** `lib/features/tracking/services/background_tracking_service.dart`

| Field | Before | After |
|---|---|---|
| `channelId` | `'gps_tracking_channel'` | `'gps_tracking_channel_v2'` |
| `channelImportance` | `DEFAULT` | `HIGH` |
| `priority` | `DEFAULT` | `HIGH` |

**Why new channel ID:** Android caches channel importance per ID; changing importance on an existing ID is silently ignored. New ID forces a fresh channel at HIGH importance.

**Why HIGH not MAX:** MAX triggers heads-up banners on every update (disruptive). HIGH gives persistent status bar + lock screen visibility — sufficient to signal importance to Samsung's memory manager.

---

## Layer B1: PackageManagerCompat (Android 11+)

Add to `gps_tracker/device_manufacturer` method channel in `MainActivity.kt`:
- `getUnusedAppRestrictionsStatus()` → int (mirrors `PackageManagerCompat` constants)
- `openManageUnusedAppRestrictionsSettings()` → calls `IntentCompat.createManageUnusedAppRestrictionsIntent()`

Wire into `AndroidBatteryHealthService` (Dart). Add `isUnusedAppRestrictionsActive` to `PermissionGuardState`. Block clock-in and show banner when status is `API_30`, `API_30_BACKPORT`, or `API_31`.

**Zero effect on Android ≤10** (returns `FEATURE_NOT_AVAILABLE`). Pure future-proofing.

**Pre-flight:** Verify `androidx.core:core-ktx >= 1.7.0` in `android/app/build.gradle`.

---

## Layer B2: Mandatory OEM Guide Dialog + Server Tracking

**Files:** `oem_battery_guide_dialog.dart`, `supabase/migrations/104_battery_setup_tracking.sql`, `user_management_screen.dart`

### Dialog Changes
- Convert to `StatefulWidget`
- `showIfNeeded()`: checks actual battery optimization state instead of `oem_setup_completed` flag
- `barrierDismissible: false` — no tap-outside dismiss
- Remove "Plus tard" button
- `_confirmDone()`: calls `FlutterForegroundTask.isIgnoringBatteryOptimizations` before closing; shows inline error if still not fixed
- `_openOemSettings()`: tracks that user opened settings (enables "C'est fait" button)
- `_syncCompletionToServer()`: fire-and-forget RPC call to `mark_battery_setup_completed`

### Migration 104
```sql
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS battery_setup_completed_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION mark_battery_setup_completed()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER ...
-- Only first-time (never regresses): WHERE battery_setup_completed_at IS NULL
```

### Admin UI
`user_management_screen.dart`: battery alert icon next to Android employees who have `battery_setup_completed_at IS NULL`.

---

## Layer UX: Visual Signals

### Settings Warning Chip (Task 5)
New `ClockButtonSettingsWarning` widget (Android-only):
- Appears below clock button when `shouldBlockClockIn` due to battery/standby issues
- Tapping opens `BatteryHealthScreen` directly
- Disappears when issues resolved

### Persistent Regression Banner (Task 6)
In `_checkBatteryHealthOnResume()`:
- After showing the repair dialog chain, if battery exemption is STILL missing AND a shift is active → show `MaterialBanner` at Scaffold level
- "Corriger" button re-opens `BatteryOptimizationDialog.show(context)` (no `forceOemGuide` — state check handles it)
- "Plus tard" dismisses (kept: employee may be driving)
- Banner dismissed on clock-out via `ScaffoldMessenger.clearMaterialBanners()`

### Shareable Diagnostic Report (Task 7)
In `BatteryHealthScreen`:
- `_buildDiagnosticReport()`: collects platform, manufacturer, battery exemption, standby bucket, location permission, app version
- "Copier le rapport de diagnostic" button: copies text to clipboard + SnackBar confirmation

---

## Layer C: Native 60s AlarmManager Rescue Watchdog

### TrackingRescueReceiver.kt
```
New file: android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt
```

- `startAlarmChain()`: schedules exact alarm at T+60s (`setExactAndAllowWhileIdle`)
- `onReceive()`: reads `shift_id` from FFT SharedPreferences
  - If `shift_id` present → calls `startForegroundService(FFT)` unconditionally → reschedules next alarm
  - If `shift_id` absent → chain stops naturally (clock-out race safety)
- Android 12+ without `canScheduleExactAlarms()`: falls back to inexact `setAndAllowWhileIdle()`

### Method Channel (MainActivity.kt)
Two new cases in `gps_tracker/device_manufacturer`:
- `startRescueAlarms(shiftId)` → `TrackingRescueReceiver.startAlarmChain()`
- `stopRescueAlarms()` → `TrackingRescueReceiver.stopAlarmChain()`

### Tracking Service Integration
- `background_tracking_service.dart`: `startRescueAlarms(shiftId)` after successful `FlutterForegroundTask.startService()`
- `background_tracking_service.dart`: `stopRescueAlarms()` as first call in `stopTracking()`

### AndroidManifest.xml additions
```xml
<receiver android:name=".TrackingRescueReceiver" android:exported="false" />
<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
```

---

## Data Flow During Shift

```
Clock-in
  → FlutterForegroundTask.startService()     [HIGH importance channel v2]
  → startRescueAlarms(shiftId)               [60s AlarmManager chain]
  [WorkManager 5-min watchdog: unchanged]

Screen off / app switched (Samsung kills FFT)
  → ~60s: TrackingRescueReceiver fires
    → reads shift_id from SharedPrefs
    → startForegroundService(FFT)            [service restarted]
    → reschedules next alarm T+60s

Resume from background (battery regression detected)
  → BatteryOptimizationDialog.show()
  → OemBatteryGuideDialog.showIfNeeded()     [auto-shows, state is bad]
  → If still bad + active shift: MaterialBanner persists

Clock-out
  → FlutterForegroundTask.stopService()
  → stopRescueAlarms()                       [alarm chain stopped]
  → shift_id cleared from SharedPrefs
  → ScaffoldMessenger.clearMaterialBanners()
```

---

## Error Handling

- **B1 `core-ktx` missing:** `PackageManagerCompat` throws → catch, return `FEATURE_NOT_AVAILABLE` (fail-open)
- **C no exact alarm permission (Android 12):** `canScheduleExactAlarms()` returns false → inexact `setAndAllowWhileIdle()`; WorkManager covers gap
- **C receiver fires after clock-out:** `shift_id` empty in SharedPrefs → receiver does nothing, does NOT reschedule
- **B2 server sync fails:** `_syncCompletionToServer()` is fire-and-forget, catches all exceptions; local `oem_setup_completed` flag is source of truth for the app
- **Old notification channel:** orphaned in system settings, silently ignored

---

## Testing

- **Layer A:** Samsung S9 — clock in, switch apps, verify HIGH-importance notification stays in status bar after 3 min
- **Layer B1:** Android 11+ device — set hibernatable → verify clock-in blocked with banner
- **Layer B2:** Enable battery optimization → try to clock in → verify OEM dialog appears with no "Plus tard" → tap "C'est fait" without fixing → verify inline error → fix → tap "C'est fait" → verify dialog closes
- **Layer C:** Force-stop FFT: `adb shell am kill ca.trilogis.gpstracker` → wait 90s → verify restart
- **Layer C clock-out:** Clock out → wait 2 min → verify no further `TrackingRescueReceiver` logcat entries

---

## Task Summary (implementation order)

| # | Task | Layer | Key files |
|---|---|---|---|
| 1 | Raise notification importance | A | `background_tracking_service.dart` |
| 2 | PackageManagerCompat (Kotlin) | B1 | `MainActivity.kt` |
| 3 | Wire unused app restrictions (Dart) | B1 | `android_battery_health_service.dart`, `permission_guard_*`, `permission_status_banner.dart` |
| 4 | Mandatory OEM guide + migration 104 | B2 | `oem_battery_guide_dialog.dart`, `104_battery_setup_tracking.sql`, `user_management_screen.dart` |
| 5 | Settings warning chip | UX | `clock_button_settings_warning.dart`, `shift_dashboard_screen.dart` |
| 6 | Persistent regression banner | UX | `shift_dashboard_screen.dart` |
| 7 | Shareable diagnostic report | UX | `battery_health_screen.dart` |
| 8 | TrackingRescueReceiver (Kotlin) | C | `TrackingRescueReceiver.kt`, `AndroidManifest.xml` |
| 9 | Expose rescue alarms via channel | C | `MainActivity.kt` |
| 10 | Wire rescue alarms into Flutter | C | `android_battery_health_service.dart`, `background_tracking_service.dart` |
