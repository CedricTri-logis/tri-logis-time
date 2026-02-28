# GPS Tracking Verification Gate — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Auto clock-out after 30s if background GPS tracking fails to produce a single point, replacing the passive orange banner with an active safety net + retry dialog.

**Architecture:** Extend the existing `_startTrackingVerification()` timer from 15s→30s. On timeout, programmatically clock out via `ShiftNotifier`, stop tracking, and surface a `trackingAutoClockOutOccurred` flag that the UI reads to show a generic error dialog with a "Réessayer" button.

**Tech Stack:** Dart/Flutter, flutter_riverpod, flutter_foreground_task (existing)

---

### Task 1: Add `trackingAutoClockOutOccurred` flag to TrackingState

**Files:**
- Modify: `gps_tracker/lib/features/tracking/models/tracking_state.dart`

**Step 1: Add the field to TrackingState**

In the class fields (after `trackingStartFailed` at line 46), add:

```dart
/// Whether an auto clock-out was triggered due to tracking verification failure.
final bool trackingAutoClockOutOccurred;
```

In the constructor (after line 61), add:

```dart
this.trackingAutoClockOutOccurred = false,
```

In `copyWith` — add parameter (after line 91):

```dart
bool? trackingAutoClockOutOccurred,
```

In the `copyWith` return body (after line 108):

```dart
trackingAutoClockOutOccurred: trackingAutoClockOutOccurred ?? this.trackingAutoClockOutOccurred,
```

In `startTracking()` method (line 112) — reset the flag. Add to the `copyWith` call:

```dart
trackingAutoClockOutOccurred: false,
```

The `stopTracking()` method already returns `const TrackingState()` which defaults all bools to false — no change needed there.

**Step 2: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/models/tracking_state.dart`
Expected: No errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/models/tracking_state.dart
git commit -m "feat: add trackingAutoClockOutOccurred flag to TrackingState"
```

---

### Task 2: Transform verification timer into auto clock-out

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

**Step 1: Change timer from 15s to 30s and add auto clock-out logic**

Replace `_startTrackingVerification()` (lines 610-624) with:

```dart
  /// Start a 30-second timer to verify that background tracking is producing GPS points.
  /// If no point is received within the timeout, auto clock-out and notify UI.
  void _startTrackingVerification() {
    _verificationTimer?.cancel();
    _verificationTimer = Timer(const Duration(seconds: 30), () async {
      if (state.status == TrackingStatus.running && !state.trackingVerified) {
        final shiftId = state.activeShiftId;
        _logger?.gps(
          Severity.error,
          'Tracking verification failed: no GPS point within 30s — auto clock-out',
          metadata: {'shift_id': shiftId},
        );

        // Stop tracking first
        await stopTracking(reason: 'tracking_verification_failed');

        // Auto clock-out the shift
        try {
          await _ref.read(shiftProvider.notifier).clockOut(
                reason: 'tracking_failed',
              );
        } catch (e) {
          _logger?.gps(
            Severity.error,
            'Auto clock-out after tracking failure failed',
            metadata: {'error': e.toString(), 'shift_id': shiftId},
          );
        }

        // Signal UI to show error dialog
        state = state.copyWith(trackingAutoClockOutOccurred: true);
      }
    });
  }
```

**Step 2: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/providers/tracking_provider.dart`
Expected: No errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat: auto clock-out on 30s tracking verification failure"
```

---

### Task 3: Replace banner with error dialog in shift dashboard

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Step 1: Add a listener for `trackingAutoClockOutOccurred`**

Find the `_ShiftDashboardScreenState` class. In its `initState()` (or equivalent widget lifecycle), we need to react to the flag. Since this is a `ConsumerStatefulWidget`, the cleanest approach is to add a `ref.listen` in the `build` method.

Find the `build` method of `_ShiftDashboardScreenState`. Near the top (after existing ref.watch calls), add:

```dart
    // Listen for auto clock-out due to tracking verification failure
    ref.listen<TrackingState>(trackingProvider, (previous, next) {
      if (next.trackingAutoClockOutOccurred &&
          !(previous?.trackingAutoClockOutOccurred ?? false)) {
        _showTrackingFailureDialog();
      }
    });
```

**Step 2: Add the dialog method**

Add this method to `_ShiftDashboardScreenState`:

```dart
  void _showTrackingFailureDialog() {
    // Reset the flag so it doesn't re-trigger
    ref.read(trackingProvider.notifier).clearAutoClockOutFlag();

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Impossible de démarrer le suivi'),
        content: const Text(
          'Le suivi n\'a pas pu démarrer correctement. '
          'Veuillez réessayer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _handleClockIn();
            },
            child: const Text('Réessayer'),
          ),
        ],
      ),
    );
  }
```

**Step 3: Remove `_TrackingFailureBanner` usage and class**

At line 1202, remove the `_TrackingFailureBanner` widget from the Column children:

```dart
            // Tracking verification failure banner  <-- DELETE
            _TrackingFailureBanner(                   <-- DELETE
              hasActiveShift: hasActiveShift,          <-- DELETE
            ),                                        <-- DELETE
```

At lines 1528-1564, delete the entire `_TrackingFailureBanner` class.

**Step 4: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/screens/shift_dashboard_screen.dart`
Expected: No errors

**Step 5: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: replace tracking failure banner with auto clock-out dialog"
```

---

### Task 4: Add `clearAutoClockOutFlag` to TrackingNotifier

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

**Step 1: Add the method**

Add this method to `TrackingNotifier` (near the `stopTracking` method):

```dart
  /// Clear the auto clock-out flag after the UI has shown the error dialog.
  void clearAutoClockOutFlag() {
    state = state.copyWith(trackingAutoClockOutOccurred: false);
  }
```

**Step 2: Run analyzer**

Run: `cd gps_tracker && flutter analyze lib/features/tracking/providers/tracking_provider.dart`
Expected: No errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat: add clearAutoClockOutFlag method to TrackingNotifier"
```

---

### Task 5: Full build verification

**Step 1: Run full analyzer**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors related to tracking_state, tracking_provider, or shift_dashboard_screen

**Step 2: Run tests**

Run: `cd gps_tracker && flutter test`
Expected: All existing tests pass

**Step 3: Final commit if any fixups needed**

If analyzer or tests revealed issues, fix and commit.
