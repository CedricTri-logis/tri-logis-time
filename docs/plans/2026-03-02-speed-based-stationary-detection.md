# Speed-Based Stationary Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the broken distance-based stationary detection with a speed-based approach so that GPS capture drops to 120s when employees are truly stopped (instead of staying at 10s on 67% of Android devices).

**Architecture:** Use the GPS sensor's `speed` field as the primary stationary signal. When speed < 0.5 m/s for 3 consecutive minutes, switch to 120s capture interval. When any single reading shows speed >= 0.5 m/s, immediately switch back to 10s. The existing distance-based `_checkStationaryState` is replaced entirely — the new logic lives in a simplified `_updateStationaryState` method. The GPS position stream remains always-on; only the save-or-skip decision changes.

**Tech Stack:** Dart/Flutter, geolocator (Position.speed), flutter_foreground_task (background handler)

---

### Task 1: Add unit tests for speed-based stationary detection

**Files:**
- Create: `gps_tracker/test/features/tracking/stationary_detection_test.dart`

This task extracts the stationary detection logic into a testable pure-Dart class, then writes tests covering all transitions.

**Step 1: Create the test file with all test cases**

```dart
import 'package:flutter_test/flutter_test.dart';

/// Minimal Position-like class for testing (avoids geolocator dependency).
class FakePosition {
  final double speed;
  FakePosition({required this.speed});
}

/// Extracted stationary detection logic — mirrors the handler's behavior.
/// This class is ONLY for testing. The real logic lives in GPSTrackingHandler.
class StationaryDetector {
  bool isStationary = false;
  DateTime? _lowSpeedSince;
  static const stationaryDelay = Duration(minutes: 3);

  /// Call on every GPS position update. Returns the new isStationary state.
  bool update(double speed, DateTime now) {
    if (speed >= 0.5) {
      // Any movement → immediately active
      isStationary = false;
      _lowSpeedSince = null;
      return false;
    }

    // speed < 0.5 — track how long
    _lowSpeedSince ??= now;

    if (now.difference(_lowSpeedSince!) >= stationaryDelay) {
      isStationary = true;
    }

    return isStationary;
  }
}

void main() {
  group('StationaryDetector', () {
    late StationaryDetector detector;
    late DateTime t;

    setUp(() {
      detector = StationaryDetector();
      t = DateTime(2026, 3, 2, 8, 0, 0); // arbitrary start
    });

    test('starts as not stationary', () {
      expect(detector.isStationary, isFalse);
    });

    test('stays active when speed >= 0.5', () {
      detector.update(5.0, t);
      expect(detector.isStationary, isFalse);

      detector.update(0.5, t.add(const Duration(seconds: 10)));
      expect(detector.isStationary, isFalse);
    });

    test('does NOT become stationary before 3 minutes', () {
      // Feed low speed for 2 min 59 sec
      for (var i = 0; i < 18; i++) {
        detector.update(0.1, t.add(Duration(seconds: i * 10)));
      }
      // At 2:59
      detector.update(0.1, t.add(const Duration(minutes: 2, seconds: 59)));
      expect(detector.isStationary, isFalse);
    });

    test('becomes stationary after exactly 3 minutes of low speed', () {
      detector.update(0.1, t); // start
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);
    });

    test('exits stationary IMMEDIATELY on one high-speed reading', () {
      // Become stationary
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);

      // One moving reading
      detector.update(0.6, t.add(const Duration(minutes: 3, seconds: 10)));
      expect(detector.isStationary, isFalse);
    });

    test('requires full 3 minutes again after reset', () {
      // Become stationary
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);

      // Movement resets
      detector.update(0.6, t.add(const Duration(minutes: 3, seconds: 10)));
      expect(detector.isStationary, isFalse);

      // 1 minute of low speed — not enough
      detector.update(0.1, t.add(const Duration(minutes: 3, seconds: 11)));
      detector.update(0.1, t.add(const Duration(minutes: 4, seconds: 11)));
      expect(detector.isStationary, isFalse);

      // 3 more minutes from reset point
      detector.update(0.1, t.add(const Duration(minutes: 6, seconds: 11)));
      expect(detector.isStationary, isTrue);
    });

    test('single speed blip resets the 3-minute timer', () {
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 2)));
      expect(detector.isStationary, isFalse);

      // Blip at 2 min
      detector.update(0.8, t.add(const Duration(minutes: 2, seconds: 1)));
      expect(detector.isStationary, isFalse);

      // Low speed resumes — needs 3 full min from blip
      detector.update(0.1, t.add(const Duration(minutes: 2, seconds: 2)));
      detector.update(0.1, t.add(const Duration(minutes: 5, seconds: 1)));
      expect(detector.isStationary, isFalse);

      detector.update(0.1, t.add(const Duration(minutes: 5, seconds: 2)));
      expect(detector.isStationary, isTrue);
    });

    test('handles null/negative speed as stationary-capable', () {
      // speed < 0 treated as "no data" by geolocator — handler filters these
      // before calling update, so we only test speed >= 0 here
      detector.update(0.0, t);
      detector.update(0.0, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);
    });
  });
}
```

**Step 2: Run the tests to verify they pass**

Run: `cd gps_tracker && flutter test test/features/tracking/stationary_detection_test.dart -v`
Expected: All 7 tests PASS (these test the extracted logic, not the handler itself)

**Step 3: Commit**

```bash
git add gps_tracker/test/features/tracking/stationary_detection_test.dart
git commit -m "test: add unit tests for speed-based stationary detection"
```

---

### Task 2: Replace distance-based detection with speed-based in the background handler

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`

This is the core change. We replace `_checkStationaryState` (distance-based, broken on most Android) with `_updateStationaryState` (speed-based, 3-minute confirmation).

**Step 1: Replace the state fields**

In the class fields (top of file, around lines 18-21), replace:

```dart
  bool _isStationary = false;
  DateTime? _stationaryCheckTime;
```

with:

```dart
  bool _isStationary = false;
  DateTime? _lowSpeedSince; // When speed first dropped below 0.5 m/s
  static const _stationaryDelay = Duration(minutes: 3);
```

**Step 2: Replace `_checkStationaryState` with `_updateStationaryState`**

Replace the entire `_checkStationaryState` method (lines 265-305) with:

```dart
  /// Speed-based stationary detection.
  ///
  /// Uses the GPS sensor's speed field (reliable across all devices) instead
  /// of distance-between-points (broken on Android with 10-40m accuracy due
  /// to positional drift resetting the timer).
  ///
  /// - speed >= 0.5 m/s → immediately active (10s interval)
  /// - speed < 0.5 m/s for 3 consecutive minutes → stationary (120s interval)
  ///
  /// Asymmetric by design: slow to enter stationary (avoids false slowdown at
  /// traffic lights), instant to exit (never miss a departure).
  void _updateStationaryState(Position position, DateTime now) {
    final speed = position.speed;

    // Negative speed means geolocator has no speed data — treat as unknown,
    // don't change state (fail-open: keep current mode).
    if (speed < 0) return;

    if (speed >= 0.5) {
      // Any movement → immediately active
      if (_isStationary) {
        _sendDiagnostic('info', 'Exiting stationary mode (speed=${speed.toStringAsFixed(1)} m/s)');
      }
      _isStationary = false;
      _lowSpeedSince = null;
      return;
    }

    // speed < 0.5 — track how long we've been low-speed
    _lowSpeedSince ??= now;

    if (!_isStationary && now.difference(_lowSpeedSince!) >= _stationaryDelay) {
      _isStationary = true;
      _sendDiagnostic('info', 'Entering stationary mode after 3 min low speed');
    }
  }
```

**Step 3: Update `_computeInterval` doc comment**

Replace the `_computeInterval` method (lines 250-263) with:

```dart
  /// Compute capture interval: 10s when active, 120s when confirmed stationary.
  /// Stationary = speed < 0.5 m/s for 3+ consecutive minutes.
  /// Applies thermal multiplier.
  Duration _computeInterval(Position position) {
    int intervalSec = _isStationary ? _stationaryIntervalSeconds : _activeIntervalSeconds;

    // Apply thermal multiplier
    intervalSec *= _thermalMultiplier;

    return Duration(seconds: intervalSec);
  }
```

Note: also replaces hardcoded `10` with `_activeIntervalSeconds` for consistency.

**Step 4: Update `_onPosition` to call the new method**

In `_onPosition` (around line 224-225), change:

```dart
    // Check for stationary state (distance-based fallback)
    _checkStationaryState(position, now);
```

to:

```dart
    // Update stationary state (speed-based, 3-minute confirmation)
    _updateStationaryState(position, now);
```

**Step 5: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No new errors or warnings

**Step 6: Run all tests**

Run: `cd gps_tracker && flutter test`
Expected: All tests pass (including the new stationary detection tests from Task 1)

**Step 7: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart
git commit -m "fix: replace distance-based stationary detection with speed-based (3-min delay)

Distance-based detection failed on 67% of Android devices due to GPS
positional drift (10-40m accuracy) resetting the 5-minute timer.
Speed sensor is reliable across all devices. New logic:
- speed >= 0.5 m/s → active (10s interval), instant transition
- speed < 0.5 m/s for 3 min → stationary (120s interval)
Saves ~90% of redundant GPS points during stationary periods."
```

---

### Task 3: Update TrackingConfig.intervalForSpeed to match new logic

**Files:**
- Modify: `gps_tracker/lib/features/tracking/models/tracking_config.dart`

The `intervalForSpeed` method in TrackingConfig is not used by the handler (the handler uses `_isStationary` directly), but its doc comments reference the old system. Update for consistency.

**Step 1: Update the method and doc comment**

Replace lines 44-57 in `tracking_config.dart`:

```dart
  /// Compute capture interval based on speed.
  ///
  /// Two-tier system:
  /// - Active (speed >= 0.5 m/s, or low speed < 3 min): 10s
  /// - Confirmed stationary (speed < 0.5 m/s for 3+ min): 120s
  ///
  /// Note: Actual stationary detection is time-based in the background
  /// handler's `_updateStationaryState()`. This method is a simplified
  /// snapshot that doesn't account for the 3-minute delay.
  int intervalForSpeed(double? speedMs) {
    if (speedMs == null || speedMs < 0) return activeIntervalSeconds;
    if (speedMs < 0.5) return stationaryIntervalSeconds;
    return activeIntervalSeconds;
  }
```

**Step 2: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/models/tracking_config.dart
git commit -m "docs: update TrackingConfig.intervalForSpeed doc to match speed-based detection"
```

---

### Task 4: Verify no other code depends on removed `_stationaryCheckTime`

**Files:**
- Search only (no changes expected)

**Step 1: Search for any references to the removed field**

Run: `cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker && grep -r "stationaryCheckTime\|_checkStationaryState" gps_tracker/lib/`
Expected: Zero results (all references were in the handler file and have been replaced)

**Step 2: Search for any code that reads `_isStationary` outside the handler**

Run: `cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker && grep -r "_isStationary\|isStationary" gps_tracker/lib/`
Expected: Only results in `gps_tracking_handler.dart` — the field is private to the handler

**Step 3: Run full test suite one final time**

Run: `cd gps_tracker && flutter test`
Expected: All tests pass

**Step 4: Final commit (bump build if deploying)**

No code changes needed unless the search finds unexpected references.

---

## Summary of Changes

| File | Change |
|---|---|
| `gps_tracking_handler.dart` | Replace `_stationaryCheckTime` → `_lowSpeedSince`, `_checkStationaryState()` → `_updateStationaryState()`, fix hardcoded `10` → `_activeIntervalSeconds` |
| `tracking_config.dart` | Update doc comment only |
| `stationary_detection_test.dart` | New test file (7 test cases) |

**Total: ~40 lines changed, ~80 lines of tests added. Zero new dependencies.**

## Expected Impact

| Metric | Before | After |
|---|---|---|
| Stationary points/hour (Android) | ~360 (every 10s) | ~30 (every 120s) |
| Stationary detection on Android | 33% working | 100% working |
| Movement detection delay | 0s | 0-15s (1 GPS stream cycle) |
| Battery drain (stationary) | Higher (frequent writes) | Lower (~90% fewer writes) |
