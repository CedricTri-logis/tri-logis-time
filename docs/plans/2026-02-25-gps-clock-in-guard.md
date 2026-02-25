# GPS Clock-In Guard & Tracking Resilience — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent clock-in if GPS is not working, and fix the race condition that causes background tracking to silently fail on rapid clock-out/clock-in cycles.

**Architecture:** Three-layer fix: (1) Pre-clock-in GPS health check that captures a real GPS point and blocks clock-in if GPS doesn't respond within timeout, (2) Fix the tracking start race condition where quick re-clock-in finds the old foreground service still running and silently skips starting a new one, (3) Post-clock-in tracking verification that detects if background tracking fails to start and alerts the user.

**Tech Stack:** Dart/Flutter, flutter_foreground_task, geolocator, Riverpod, SQLCipher

---

## Research Findings

### Jessy Mainville's Data (iPhone 12, iOS 26.2.1, v1.0.0+64)

**15 out of 20 shifts in February have 0 GPS points.** All 15 have `last_heartbeat_at: null` — background tracking never started.

| Period | Shifts | GPS Working | GPS Broken |
|--------|--------|------------|------------|
| Feb 3-19 | 14 | 0 | 14 (100% broken) |
| Feb 23-25 | 6 | 5 | 1 (current) |

**Feb 3-19 (all broken):** Likely an older app version or initial permission issue. Background service never started for any shift — no heartbeats, no GPS points.

**Feb 25 current shift (broken):** Classic race condition. She clocked out a 1-minute shift at 20:33:52 and clocked in again at 20:34:30 — only **38 seconds later**. Diagnostic logs show the first shift had full tracking ("Tracking started", heartbeat, 1 GPS point), but the second shift has **zero diagnostic logs** after clock-in.

### The Race Condition (Bug #1 — Critical)

**Location:** `tracking_provider.dart:512-563` + `background_tracking_service.dart:82-84`

When user clocks out then quickly clocks in:

1. Clock-out triggers `_verifyAndStopTracking()` (async) → calls `BackgroundTrackingService.stopTracking()` → `FlutterForegroundTask.stopService()`
2. Stop is **asynchronous** — takes time for the old service to actually die
3. 38 seconds later, clock-in succeeds → `_handleShiftStateChange()` fires → `startTracking()`
4. Two failure modes:

   **Mode A — State guard:** If `state.status` is still `TrackingStatus.running` (the 'stopped' message hasn't arrived yet), `startTracking()` silently returns at line 518-520:
   ```dart
   if (state.status == TrackingStatus.running ||
       state.status == TrackingStatus.starting) {
     return; // ← SILENTLY SKIPS new shift tracking
   }
   ```

   **Mode B — Service still running:** If `FlutterForegroundTask.isRunningService` returns true (old service hasn't fully stopped), it returns `TrackingAlreadyActive`, which is handled as:
   ```dart
   case TrackingAlreadyActive():
     state = state.copyWith(status: TrackingStatus.running);
     // ← Sets state to "running" but service is tracking the OLD shift ID!
   ```
   The old service eventually stops (old shift is completed), sends 'stopped' → state goes to `TrackingStatus.stopped`. But `_handleShiftStateChange` already fired and won't fire again.

**Result:** New shift has no tracking. No GPS points. No heartbeat. Zero diagnostic logs (the clock-in GPS point we added earlier is the only data).

### Broader Impact — Not Just Jessy

| Employee | Device | Zero GPS % | Notes |
|----------|--------|-----------|-------|
| Keven Aubry | unknown | 100% (2/2) | Never installed? |
| **Jessy Mainville** | iPhone 12, iOS 26.2.1 | **75% (15/20)** | Race condition + old version |
| **Irene Pepin** | iPhone 11, iOS 18.3.2 | **56% (9/16)** | Old app version +55 |
| Gerald Veillette | Samsung S21 FE | 43% (3/7) | Old version +53 |
| Vincent Thuot | Samsung S23 | 25% (2/8) | Old version +49 |

The pattern: employees on **older app versions** have high zero-GPS rates, suggesting the bug has existed for a while. But even on the latest version (+64), the race condition can still trigger it.

### iOS-Specific Considerations (iPhone 12)

1. **`flutter_foreground_task` on iOS:** The package works differently on iOS vs Android. On iOS, there's no real "foreground service" — the background execution relies on `UIBackgroundModes: location` + the geolocator stream keeping the app alive. The `isRunningService` check may not accurately reflect whether the GPS stream is actually receiving data.

2. **`getCurrentPosition()` kills position stream on iOS:** Known geolocator bug (#999, #1191). Calling `getCurrentPosition()` while a `getPositionStream()` is active can cause the stream to silently die. The codebase already works around this in the background handler (uses `getLastKnownPosition()` instead), but the **pre-clock-in location capture** via `captureClockLocation()` calls `getCurrentPosition()` — if a previous shift's stream is still alive, this can kill it.

3. **Live Activity failure:** Jessy's logs show `PlatformException(LIVE_ACTIVITY_ERROR, can't launch live activity...)`. This is handled gracefully (try/catch) but indicates the ActivityKit setup has an issue on her device.

---

## Task 1: Fix Race Condition — Stop-Before-Start Guard

**Problem:** When `startTracking()` is called while the old service is still stopping, it either silently returns or sets state to "running" without actually starting a new service.

**Fix:** If the service is already running when we try to start for a NEW shift, stop it first and wait, then start the new one.

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` (lines 512-563)
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` (lines 76-139)

**Step 1: Add `restartTracking()` to BackgroundTrackingService**

In `background_tracking_service.dart`, add a method that stops the old service and starts a new one:

```dart
/// Stop any running service, then start a new one for the given shift.
/// Handles the race condition when clock-out stop hasn't completed
/// before the next clock-in starts.
static Future<TrackingResult> restartTracking({
  required String shiftId,
  required String employeeId,
  DateTime? clockedInAt,
  TrackingConfig config = const TrackingConfig(),
}) async {
  // Stop any existing service first
  if (await FlutterForegroundTask.isRunningService) {
    _logger?.gps(Severity.warn, 'Stopping stale service before restart', metadata: {
      'new_shift_id': shiftId,
    });
    await stopTracking();
    // Brief wait for iOS to fully release the service
    await Future.delayed(const Duration(milliseconds: 500));
  }

  return startTracking(
    shiftId: shiftId,
    employeeId: employeeId,
    clockedInAt: clockedInAt,
    config: config,
  );
}
```

**Step 2: Update `TrackingNotifier.startTracking()` to handle race condition**

In `tracking_provider.dart`, replace the current `startTracking()` method. Key changes:
- Remove the silent early return for `TrackingStatus.running` — instead check if we're tracking the CORRECT shift
- For `TrackingAlreadyActive`, use `restartTracking()` instead of just setting state

```dart
/// Begin background tracking for the active shift.
Future<void> startTracking({TrackingConfig? config}) async {
  final shiftState = _ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  if (shift == null) return;

  // If already tracking THIS shift, skip
  if ((state.status == TrackingStatus.running ||
       state.status == TrackingStatus.starting) &&
      state.activeShiftId == shift.id) {
    return;
  }

  // If "running" for a DIFFERENT shift (stale state), force restart
  final needsRestart = state.status == TrackingStatus.running &&
      state.activeShiftId != null &&
      state.activeShiftId != shift.id;

  state = state.startTracking(shift.id);

  final trackingConfig = config ?? state.config;
  final TrackingResult result;

  if (needsRestart) {
    _logger?.gps(Severity.warn, 'Restarting tracking for new shift', metadata: {
      'old_shift_id': state.activeShiftId,
      'new_shift_id': shift.id,
    });
    result = await BackgroundTrackingService.restartTracking(
      shiftId: shift.id,
      employeeId: shift.employeeId,
      clockedInAt: shift.clockedInAt,
      config: trackingConfig,
    );
  } else {
    result = await BackgroundTrackingService.startTracking(
      shiftId: shift.id,
      employeeId: shift.employeeId,
      clockedInAt: shift.clockedInAt,
      config: trackingConfig,
    );
  }

  switch (result) {
    case TrackingSuccess():
      state = state.copyWith(
        status: TrackingStatus.running,
        config: trackingConfig,
      );
      ShiftActivityService.instance.startActivity(shift);
      SignificantLocationService.onWokenByLocationChange = _onWokenByLocationChange;
      SignificantLocationService.startMonitoring();
      _significantLocationActive = true;
      BackgroundTrackingService.onForegroundServiceDied = _onForegroundServiceDied;
      BackgroundExecutionService.startBackgroundSession();
      BackgroundTrackingService.startLifecycleObserver();
      _startThermalMonitoring();
      _logger?.gps(Severity.info, 'Tracking started', metadata: {'shift_id': shift.id});
    case TrackingPermissionDenied():
      _logger?.permission(Severity.warn, 'Location permission denied for tracking');
      state = state.withError('Location permission required');
    case TrackingServiceError(:final message):
      _logger?.gps(Severity.error, 'Tracking service error', metadata: {'message': message});
      state = state.withError(message);
    case TrackingAlreadyActive():
      // Service is still running from the old shift — restart it
      _logger?.gps(Severity.warn, 'Service already active, forcing restart');
      final restartResult = await BackgroundTrackingService.restartTracking(
        shiftId: shift.id,
        employeeId: shift.employeeId,
        clockedInAt: shift.clockedInAt,
        config: trackingConfig,
      );
      if (restartResult is TrackingSuccess) {
        state = state.copyWith(
          status: TrackingStatus.running,
          config: trackingConfig,
        );
        ShiftActivityService.instance.startActivity(shift);
        SignificantLocationService.onWokenByLocationChange = _onWokenByLocationChange;
        SignificantLocationService.startMonitoring();
        _significantLocationActive = true;
        BackgroundTrackingService.onForegroundServiceDied = _onForegroundServiceDied;
        BackgroundExecutionService.startBackgroundSession();
        BackgroundTrackingService.startLifecycleObserver();
        _startThermalMonitoring();
        _logger?.gps(Severity.info, 'Tracking restarted for new shift', metadata: {'shift_id': shift.id});
      } else {
        _logger?.gps(Severity.error, 'Tracking restart failed', metadata: {'shift_id': shift.id});
        state = state.withError('Failed to restart GPS tracking');
      }
  }
}
```

**Step 3: Run `flutter analyze` on both files**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/providers/tracking_provider.dart lib/features/tracking/services/background_tracking_service.dart
```
Expected: No errors

**Step 4: Commit**

```bash
git add lib/features/tracking/providers/tracking_provider.dart lib/features/tracking/services/background_tracking_service.dart
git commit -m "fix: Race condition when tracking restarts for rapid clock-out/clock-in cycles"
```

---

## Task 2: GPS Health Check Before Clock-In

**Problem:** Clock-in currently only checks that location *permissions* are granted and that `getCurrentPosition()` returns *something* (including stale `getLastKnownPosition()` fallback). It never verifies the GPS hardware is actually producing live data. Users can clock in with a stale cached position while the GPS is broken.

**Fix:** Replace the permissive location capture with a strict GPS health check:
1. Require a **fresh** GPS fix (no `getLastKnownPosition()` fallback)
2. Use a reasonable timeout (10 seconds)
3. Validate accuracy (reject if > 100m — means GPS is struggling)
4. If GPS fails → show clear error dialog explaining the problem, block clock-in

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/location_service.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Step 1: Add a strict GPS health check method to LocationService**

In `location_service.dart`, add a new method that does NOT fall back to last known position:

```dart
/// Strict GPS health check for clock-in validation.
/// Returns a fresh GPS fix or null if GPS is not working.
/// Unlike [captureClockLocation], this does NOT fall back to last known position.
Future<({GeoPoint? location, double? accuracy, String? failureReason})> verifyGpsForClockIn() async {
  final hasPermission = await ensureLocationPermission();
  if (!hasPermission) {
    return (location: null, accuracy: null, failureReason: 'permission_denied');
  }

  try {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    );

    // Reject positions with very poor accuracy (GPS not locked)
    if (position.accuracy > 100) {
      return (
        location: GeoPoint(
          latitude: position.latitude,
          longitude: position.longitude,
        ),
        accuracy: position.accuracy,
        failureReason: 'poor_accuracy',
      );
    }

    return (
      location: GeoPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      ),
      accuracy: position.accuracy,
      failureReason: null,
    );
  } on TimeoutException {
    return (location: null, accuracy: null, failureReason: 'timeout');
  } catch (e) {
    return (location: null, accuracy: null, failureReason: 'error:$e');
  }
}
```

**Step 2: Update `_handleClockIn` to use strict GPS check**

In `shift_dashboard_screen.dart`, replace the current location capture block (lines 187-219) with the new strict check. Change the snackbar text, and replace `_showLocationCaptureFailedDialog()` with a more informative `_showGpsNotWorkingDialog()`:

```dart
// Show loading indicator
if (!mounted) return;

ScaffoldMessenger.of(context).showSnackBar(
  const SnackBar(
    content: Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
        SizedBox(width: 16),
        Text('Vérification du GPS...'),
      ],
    ),
    duration: Duration(seconds: 12),
  ),
);

// Strict GPS health check — requires fresh position, no stale fallback
final gpsResult = await locationService.verifyGpsForClockIn();

if (!mounted) return;
ScaffoldMessenger.of(context).hideCurrentSnackBar();

if (gpsResult.failureReason != null) {
  _showGpsNotWorkingDialog(gpsResult.failureReason!);
  return;
}
```

Then use `gpsResult.location!` and `gpsResult.accuracy` for the clock-in call.

**Step 3: Add `_showGpsNotWorkingDialog()` method**

```dart
void _showGpsNotWorkingDialog(String reason) {
  final String title;
  final String message;

  switch (reason) {
    case 'timeout':
      title = 'GPS non disponible';
      message = 'Impossible d\'obtenir votre position GPS. '
          'Assurez-vous d\'être dans un endroit avec un signal GPS '
          '(à l\'extérieur ou près d\'une fenêtre) et réessayez.';
    case 'poor_accuracy':
      title = 'Signal GPS faible';
      message = 'Le signal GPS est trop faible pour démarrer le quart. '
          'Attendez quelques secondes pour un meilleur signal ou '
          'déplacez-vous vers un endroit plus ouvert.';
    case 'permission_denied':
      title = 'Permission GPS requise';
      message = 'L\'accès à la localisation est nécessaire pour '
          'démarrer un quart de travail.';
    default:
      title = 'Erreur GPS';
      message = 'Une erreur est survenue avec le GPS. '
          'Veuillez réessayer dans quelques instants.';
  }

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
```

**Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze lib/features/shifts/services/location_service.dart lib/features/shifts/screens/shift_dashboard_screen.dart
```
Expected: No errors

**Step 5: Commit**

```bash
git add lib/features/shifts/services/location_service.dart lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: Strict GPS health check blocks clock-in if GPS not working"
```

---

## Task 3: Post-Clock-In Tracking Verification

**Problem:** Even with the race condition fix and GPS health check, background tracking can still fail to start (iOS kills service, permission revoked mid-shift, etc.). Currently this fails silently — the user sees "Quart demarré!" but has no idea tracking isn't running.

**Fix:** After clock-in succeeds and tracking starts, verify within 15 seconds that at least one GPS point was captured by the background service. If not, show a persistent warning banner.

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- Modify: `gps_tracker/lib/features/tracking/models/tracking_state.dart`

**Step 1: Add `trackingVerified` flag to TrackingState**

In `tracking_state.dart`, add a new field:

```dart
final bool trackingVerified; // true once first background GPS point is received
```

Initialize to `false`, set to `true` in `recordPoint()`, reset to `false` in `startTracking()`.

**Step 2: Add verification timer to TrackingNotifier**

In `tracking_provider.dart`, after `startTracking()` returns `TrackingSuccess`, set a 15-second timer:

```dart
// Verify tracking actually produces a GPS point within 15 seconds
_startTrackingVerification();
```

```dart
Timer? _verificationTimer;

void _startTrackingVerification() {
  _verificationTimer?.cancel();
  _verificationTimer = Timer(const Duration(seconds: 15), () {
    if (state.status == TrackingStatus.running && !state.trackingVerified) {
      _logger?.gps(Severity.error, 'Tracking verification failed — no GPS point after 15s');
      state = state.copyWith(trackingStartFailed: true);
    }
  });
}
```

Cancel the timer in `_handlePositionUpdate()` once the first point arrives:

```dart
if (!state.trackingVerified) {
  _verificationTimer?.cancel();
  _logger?.gps(Severity.info, 'Tracking verified — first GPS point received');
}
```

**Step 3: Show warning banner in shift_dashboard_screen.dart**

Watch the tracking state and show a warning if `trackingStartFailed` is true:

```dart
// In the build method, after the shift status card:
final trackingState = ref.watch(trackingProvider);
if (trackingState.trackingStartFailed) {
  Container(
    padding: const EdgeInsets.all(12),
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.orange.shade100,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.orange),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Le suivi GPS ne fonctionne pas. Vos déplacements ne sont pas enregistrés. '
            'Essayez de fermer et rouvrir l\'application.',
            style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
          ),
        ),
      ],
    ),
  ),
}
```

**Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/providers/tracking_provider.dart lib/features/tracking/models/tracking_state.dart lib/features/shifts/screens/shift_dashboard_screen.dart
```

**Step 5: Commit**

```bash
git add lib/features/tracking/providers/tracking_provider.dart lib/features/tracking/models/tracking_state.dart lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: Post-clock-in tracking verification with warning banner"
```

---

## Task 4: Enhanced Diagnostic Logging for Clock-In Flow

**Problem:** For Jessy's current shift, we have zero diagnostic logs after clock-in, making it impossible to diagnose remotely. The logs may exist on-device but were never synced because tracking (which triggers sync) never started.

**Fix:** Add critical diagnostic logging at each step of the clock-in → tracking start pipeline, and trigger an immediate sync attempt after clock-in regardless of whether tracking started.

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- Modify: `gps_tracker/lib/features/shifts/providers/sync_provider.dart`

**Step 1: Log tracking state at clock-in time**

In `shift_provider.dart`, after clock-in success, log the current tracking state:

```dart
_logger?.shift(Severity.info, 'Clock in — tracking state at handoff', metadata: {
  'tracking_status': ref.read(trackingProvider).status.name,
  'tracking_shift_id': ref.read(trackingProvider).activeShiftId,
  'foreground_service_running': await BackgroundTrackingService.isTracking,
});
```

**Step 2: Log every decision point in `startTracking()`**

Add diagnostic logs to each branch:
- "startTracking called" with shift_id, current state, current activeShiftId
- "startTracking skipped — already tracking this shift"
- "startTracking — needs restart for new shift"
- "startTracking — TrackingAlreadyActive, forcing restart"

**Step 3: Trigger sync after clock-in**

In `shift_provider.dart`, after the clock-in GPS point insertion:

```dart
// Trigger immediate sync to flush diagnostic logs to server
// (normally sync is triggered by GPS points, but if tracking fails
// to start, logs would be stuck on-device)
try {
  _ref.read(syncProvider.notifier).notifyPendingData();
} catch (_) {}
```

**Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze lib/features/shifts/providers/shift_provider.dart lib/features/tracking/providers/tracking_provider.dart
```

**Step 5: Commit**

```bash
git add lib/features/shifts/providers/shift_provider.dart lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat: Enhanced diagnostic logging for clock-in → tracking pipeline"
```

---

## Task 5: Revert the Pre-Emptive Clock-In GPS Point (from earlier edit)

**Problem:** The change made earlier in this conversation saves the clock-in location as a GPS point. This masks the real problem — we WANT to know when tracking produces 0 points. With the GPS health check (Task 2) now requiring a fresh position, and the race condition fix (Task 1), the root causes are addressed.

**Decision:** Keep the clock-in GPS point (it's a good safety net), but make it clearly identifiable so the monitoring dashboard can distinguish "only has clock-in point" from "has real tracking points."

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

**Step 1: Tag the clock-in GPS point with a marker**

The point is already saved with `syncStatus: 'pending'`. No schema change needed — the point serves as the guaranteed minimum. The monitoring dashboard can check if `gps_count == 1` and the single point's `captured_at` matches `clocked_in_at` to detect "only clock-in point, no tracking."

This task is just a review step — verify the code from the earlier edit is clean:

```bash
cd gps_tracker && flutter analyze lib/features/shifts/providers/shift_provider.dart
```

**Step 2: Commit (if any changes)**

No commit needed if code is already clean.

---

## Task 6: Final Integration Test

**Files:** None (manual testing)

**Step 1: Test rapid clock-out/clock-in**

1. Clock in → verify GPS tracking starts (check points count in notification)
2. Clock out immediately
3. Clock in again within 30 seconds
4. Verify tracking starts for the new shift (notification shows point count incrementing)
5. Check diagnostic logs in Supabase for "Restarting tracking for new shift" or "Stopping stale service before restart"

**Step 2: Test GPS not available**

1. Go to iOS Settings → Privacy → Location Services → Turn OFF
2. Open app → try to clock in
3. Verify permission block dialog appears
4. Turn Location Services back ON
5. Put phone in airplane mode + go inside (simulate no GPS signal)
6. Try to clock in → verify "GPS non disponible" dialog appears after ~10s

**Step 3: Test tracking verification banner**

1. Clock in normally
2. Verify the warning banner does NOT appear (tracking is working)
3. To simulate failure: would need to revoke location permission mid-shift (hard to test manually)

**Step 4: Verify clock-in GPS point is synced**

1. Clock in
2. Wait 30 seconds for sync
3. Check Supabase: `SELECT count(*) FROM gps_points WHERE shift_id = '<shift_id>'`
4. Should have at least 1 point (the clock-in point) even if background tracking is slow

---

## Summary of Changes

| Task | What | Why | Risk |
|------|------|-----|------|
| 1 | Race condition fix | Old service blocks new tracking on rapid re-clock-in | Medium — changes core tracking lifecycle |
| 2 | GPS health check | Prevent clock-in when GPS hardware is broken | Low — adds a pre-check, doesn't change clock-in logic |
| 3 | Tracking verification | Alert user when background tracking fails silently | Low — additive, doesn't change tracking logic |
| 4 | Enhanced logging | Diagnose failures remotely instead of guessing | Very low — logging only |
| 5 | Review clock-in GPS point | Verify earlier change is clean | None |
| 6 | Integration test | Verify all changes work together | None |

## Execution Order

Tasks 1-4 can be done in sequence. Task 1 is the highest priority (fixes the root cause for Jessy's current issue). Task 2 is what the user specifically requested. Tasks 3-4 are defense-in-depth.
