# GPS Tracking Verification Gate

## Problem

The permission guard checks (GPS permission, battery optimization, precise location, app standby bucket) all pass, but the background foreground task silently fails to produce GPS points. The employee is clocked in with no tracking. Observed on Pixel 8a / Android 16 (SDK 36) where `app_standby_bucket` returns `UNKNOWN`.

## Solution

Transform the existing 15s passive verification timer into a 30s active safety net that auto-clocks-out the employee if the background tracking service fails to produce a single GPS point.

## Flow

```
Clock-in (unchanged)
  -> verifyGpsForClockIn() OK
  -> shift created (local + server)
  -> startTracking() -> foreground task starts
  -> _startTrackingVerification() starts 30s timer

If first GPS point arrives < 30s:
  -> timer cancelled, trackingVerified = true (existing behavior)

If no point after 30s:
  -> auto clock-out via ShiftNotifier.clockOut(reason: 'tracking_failed')
  -> stopTracking()
  -> set trackingAutoClockOutOccurred = true
  -> UI shows generic error dialog with "Retry" button
```

## Components

### 1. tracking_provider.dart — `_startTrackingVerification()`
- Timer 15s -> 30s
- On timeout: call `_ref.read(shiftProvider.notifier).clockOut(reason: 'tracking_failed')` + `stopTracking(reason: 'tracking_verification_failed')`
- Set `trackingAutoClockOutOccurred = true` on state

### 2. tracking_state.dart
- Add `trackingAutoClockOutOccurred` (bool, default false)
- Reset to false on `startTracking()` and `stopTracking()`

### 3. shift_dashboard_screen.dart
- Listen for `trackingAutoClockOutOccurred` flag
- Show generic error dialog: "Impossible de demarrer le suivi. Veuillez reessayer."
- Dialog has "Reessayer" button that calls `_handleClockIn()` to restart the full flow
- Remove or keep `_TrackingFailureBanner` as dead code cleanup (no longer reachable since auto clock-out fires before the banner would show)

### 4. shift_provider.dart
- No changes needed — `clockOut()` already supports programmatic clock-out
- `clock_out_reason: 'tracking_failed'` stored in DB for analytics

## Edge Cases

| Scenario | Behavior |
|---|---|
| GPS arrives at 29s | Timer cancelled, normal operation |
| Employee clocks out manually before 30s | Timer cancelled in stopTracking, no conflict |
| App killed during 30s | Shift stays active, midnight cleanup handles it |
| No network for clock-out | Local clock-out + sync when network returns |
| Retry succeeds | Normal clock-in flow, fresh 30s verification |
| Retry also fails | Same auto clock-out + dialog again |

## What Does NOT Change

- Pre-clock-in flow (verifyGpsForClockIn, permission guard checks)
- Foreground task startup logic (3x retry)
- Heartbeat mechanism
- GPS self-healing in background handler
