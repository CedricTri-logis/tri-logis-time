# GPS Health Guard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure GPS tracking is alive on every user interaction, with hard-gate (awaited) checks on business actions and soft (debounced, fire-and-forget) checks on all other interactions, with comprehensive diagnostic logging.

**Architecture:** A `GpsHealthGuard` singleton accessed via Riverpod. Hard gate (`ensureAlive`) is awaited before business actions and restarts GPS if dead (5s timeout, never blocks work). Soft nudge (`nudge`) is fire-and-forget with 30s debounce, triggered automatically by a `NavigatorObserver` and a `Listener` widget. All checks are logged to `DiagnosticLogger` with structured metadata.

**Tech Stack:** Dart 3.x / Flutter 3.x, flutter_riverpod 2.5.0, flutter_foreground_task 8.0.0, existing DiagnosticLogger + BackgroundTrackingService

**Design doc:** `docs/plans/2026-03-07-gps-health-guard-design.md`

---

### Task 1: Create GpsHealthGuard service

**Files:**
- Create: `gps_tracker/lib/features/tracking/services/gps_health_guard.dart`

**Step 1: Create the GpsHealthGuard class**

```dart
import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import 'background_tracking_service.dart';

/// Result of a GPS health check.
enum HealthCheckResult {
  /// Service was already running — no action needed.
  alreadyAlive,

  /// No active shift — check skipped.
  noActiveShift,

  /// Service was dead — restart succeeded.
  restartSuccess,

  /// Service was dead — restart failed or timed out.
  restartFailed,
}

/// Verifies GPS tracking is alive on user interactions.
///
/// Two modes:
/// - [ensureAlive]: Awaited (hard gate) — used before business actions.
/// - [nudge]: Fire-and-forget with 30s debounce — used on general interactions.
class GpsHealthGuard {
  DateTime? _lastCheckAt;
  bool _isRestarting = false;

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Hard gate — check if GPS tracking service is alive.
  /// If dead and an active shift exists, restart and wait up to 5 seconds.
  /// Returns result; action should always proceed regardless.
  ///
  /// [source] identifies the caller for logging (e.g. 'cleaning_scan_in').
  /// [hasActiveShift] whether a shift is currently active.
  /// [startTrackingCallback] called to restart tracking if service is dead.
  Future<HealthCheckResult> ensureAlive({
    required String source,
    required bool hasActiveShift,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) async {
    final timeSinceLastCheck = _lastCheckAt != null
        ? DateTime.now().difference(_lastCheckAt!).inSeconds
        : null;
    _lastCheckAt = DateTime.now();

    // Fast path: check if service is running
    final isRunning = await FlutterForegroundTask.isRunningService;

    if (isRunning) {
      _logger?.lifecycle(
        Severity.info,
        'GPS health check OK',
        metadata: {
          'source': source,
          'tier': 'hard',
          'service_was_alive': true,
          if (shiftId != null) 'shift_id': shiftId,
          if (timeSinceLastCheck != null)
            'time_since_last_check_s': timeSinceLastCheck,
        },
      );
      return HealthCheckResult.alreadyAlive;
    }

    // Service is not running
    if (!hasActiveShift) {
      _logger?.lifecycle(
        Severity.info,
        'GPS health check — no active shift',
        metadata: {
          'source': source,
          'tier': 'hard',
          'service_was_alive': false,
        },
      );
      return HealthCheckResult.noActiveShift;
    }

    // Service dead + active shift → restart
    if (_isRestarting) {
      // Another restart is already in progress — don't double-start
      _logger?.lifecycle(
        Severity.info,
        'GPS health check — restart already in progress',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
        },
      );
      return HealthCheckResult.restartSuccess;
    }

    _isRestarting = true;
    final stopwatch = Stopwatch()..start();

    _logger?.lifecycle(
      Severity.warn,
      'GPS health check — service dead, restarting',
      metadata: {
        'source': source,
        'tier': 'hard',
        'service_was_alive': false,
        'shift_id': shiftId,
        if (timeSinceLastCheck != null)
          'time_since_last_check_s': timeSinceLastCheck,
      },
    );

    try {
      // Start tracking with a 5-second timeout
      await startTrackingCallback().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger?.lifecycle(
            Severity.error,
            'GPS health check — restart timed out after 5s',
            metadata: {
              'source': source,
              'tier': 'hard',
              'shift_id': shiftId,
              'restart_duration_ms': stopwatch.elapsedMilliseconds,
            },
          );
        },
      );

      stopwatch.stop();

      // Verify restart actually worked
      final nowRunning = await FlutterForegroundTask.isRunningService;
      final result = nowRunning
          ? HealthCheckResult.restartSuccess
          : HealthCheckResult.restartFailed;

      _logger?.lifecycle(
        nowRunning ? Severity.info : Severity.error,
        nowRunning
            ? 'GPS health check — restart succeeded'
            : 'GPS health check — restart failed',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
          'restart_duration_ms': stopwatch.elapsedMilliseconds,
        },
      );

      return result;
    } catch (e) {
      stopwatch.stop();
      _logger?.lifecycle(
        Severity.error,
        'GPS health check — restart threw exception',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
          'restart_duration_ms': stopwatch.elapsedMilliseconds,
          'error': e.toString(),
        },
      );
      return HealthCheckResult.restartFailed;
    } finally {
      _isRestarting = false;
    }
  }

  /// Soft nudge — fire-and-forget with 30-second debounce.
  /// Call from general interactions (navigation, taps, pull-to-refresh).
  void nudge({
    required String source,
    required bool hasActiveShift,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) {
    if (!hasActiveShift) return;

    // Debounce: skip if checked within last 30 seconds
    if (_lastCheckAt != null &&
        DateTime.now().difference(_lastCheckAt!).inSeconds < 30) {
      return;
    }

    // Fire-and-forget — log with soft tier
    _lastCheckAt = DateTime.now();
    _ensureAliveSoft(
      source: source,
      shiftId: shiftId,
      startTrackingCallback: startTrackingCallback,
    );
  }

  /// Internal soft check — same logic as ensureAlive but non-blocking.
  Future<void> _ensureAliveSoft({
    required String source,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;

      if (isRunning) {
        _logger?.lifecycle(
          Severity.info,
          'GPS health check OK',
          metadata: {
            'source': source,
            'tier': 'soft',
            'service_was_alive': true,
            if (shiftId != null) 'shift_id': shiftId,
          },
        );
        return;
      }

      if (_isRestarting) return;
      _isRestarting = true;
      final stopwatch = Stopwatch()..start();

      _logger?.lifecycle(
        Severity.warn,
        'GPS health check — service dead, restarting',
        metadata: {
          'source': source,
          'tier': 'soft',
          'service_was_alive': false,
          'shift_id': shiftId,
        },
      );

      try {
        await startTrackingCallback().timeout(
          const Duration(seconds: 5),
        );
        stopwatch.stop();

        final nowRunning = await FlutterForegroundTask.isRunningService;
        _logger?.lifecycle(
          nowRunning ? Severity.info : Severity.error,
          nowRunning
              ? 'GPS health check — restart succeeded'
              : 'GPS health check — restart failed',
          metadata: {
            'source': source,
            'tier': 'soft',
            'shift_id': shiftId,
            'restart_duration_ms': stopwatch.elapsedMilliseconds,
          },
        );
      } catch (e) {
        stopwatch.stop();
        _logger?.lifecycle(
          Severity.error,
          'GPS health check — restart threw exception',
          metadata: {
            'source': source,
            'tier': 'soft',
            'shift_id': shiftId,
            'restart_duration_ms': stopwatch.elapsedMilliseconds,
            'error': e.toString(),
          },
        );
      } finally {
        _isRestarting = false;
      }
    } catch (_) {
      // Never crash for a soft nudge
    }
  }
}
```

**Step 2: Commit**

```bash
cd gps_tracker
git add lib/features/tracking/services/gps_health_guard.dart
git commit -m "feat: add GpsHealthGuard service with hard gate and soft nudge"
```

---

### Task 2: Create Riverpod provider for GpsHealthGuard

**Files:**
- Create: `gps_tracker/lib/features/tracking/providers/gps_health_guard_provider.dart`

**Step 1: Create the provider**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/providers/shift_provider.dart';
import '../services/gps_health_guard.dart';
import 'tracking_provider.dart';

/// Singleton provider for the GPS health guard.
final gpsHealthGuardProvider = Provider<GpsHealthGuard>((ref) {
  return GpsHealthGuard();
});

/// Convenience: run a hard-gate health check using current shift/tracking state.
/// Returns the result for callers that need it.
Future<HealthCheckResult> ensureGpsAlive(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  return guard.ensureAlive(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}

/// Convenience: fire a soft nudge using current shift/tracking state.
void nudgeGps(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  guard.nudge(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}
```

**Step 2: Commit**

```bash
git add lib/features/tracking/providers/gps_health_guard_provider.dart
git commit -m "feat: add Riverpod provider and convenience helpers for GpsHealthGuard"
```

---

### Task 3: Integrate hard gate into CleaningSessionNotifier

**Files:**
- Modify: `gps_tracker/lib/features/cleaning/providers/cleaning_session_provider.dart`

**Step 1: Replace fire-and-forget verifyTrackingHealth with awaited ensureGpsAlive**

In `scanIn()` (around line 173-174), replace:
```dart
// OLD: fire-and-forget, no logging
_ref.read(trackingProvider.notifier).verifyTrackingHealth();
```
with:
```dart
await ensureGpsAlive(_ref, source: 'cleaning_scan_in');
```

In `scanOut()` (around line 229-230), replace:
```dart
_ref.read(trackingProvider.notifier).verifyTrackingHealth();
```
with:
```dart
await ensureGpsAlive(_ref, source: 'cleaning_scan_out');
```

Add the import at the top:
```dart
import '../../tracking/providers/gps_health_guard_provider.dart';
```

**Step 2: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 3: Commit**

```bash
git add lib/features/cleaning/providers/cleaning_session_provider.dart
git commit -m "feat: upgrade cleaning session to use hard-gate GPS health check"
```

---

### Task 4: Integrate hard gate into MaintenanceSessionNotifier

**Files:**
- Modify: `gps_tracker/lib/features/maintenance/providers/maintenance_provider.dart`

**Step 1: Replace fire-and-forget verifyTrackingHealth with awaited ensureGpsAlive**

In `startSession()` (around line 156), replace:
```dart
_ref.read(trackingProvider.notifier).verifyTrackingHealth();
```
with:
```dart
await ensureGpsAlive(_ref, source: 'maintenance_start');
```

In `completeSession()` (around line 218), replace:
```dart
_ref.read(trackingProvider.notifier).verifyTrackingHealth();
```
with:
```dart
await ensureGpsAlive(_ref, source: 'maintenance_complete');
```

Add the import at the top:
```dart
import '../../tracking/providers/gps_health_guard_provider.dart';
```

**Step 2: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 3: Commit**

```bash
git add lib/features/maintenance/providers/maintenance_provider.dart
git commit -m "feat: upgrade maintenance session to use hard-gate GPS health check"
```

---

### Task 5: Integrate hard gate into ShiftNotifier (clockIn, clockOut)

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

**Step 1: Add hard gate to clockOut**

`clockIn` already starts GPS tracking as part of its flow, so it doesn't need a health check (GPS is freshly started). But `clockOut` should verify GPS is alive to capture the final position.

Find the `clockOut` method. Add at the very beginning of the method body (after the loading state set, before any GPS capture):
```dart
// Ensure GPS is alive for final position capture
await ensureGpsAlive(_ref, source: 'shift_clock_out');
```

Add the import at the top:
```dart
import '../../tracking/providers/gps_health_guard_provider.dart';
```

**Step 2: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 3: Commit**

```bash
git add lib/features/shifts/providers/shift_provider.dart
git commit -m "feat: add hard-gate GPS health check to shift clock-out"
```

---

### Task 6: Integrate hard gate into LunchBreakNotifier (endLunchBreak)

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart`

**Step 1: Add hard gate to endLunchBreak**

`endLunchBreak()` already calls `startTracking()` to resume GPS (line 135). But `startTracking()` may silently fail if the foreground service is in a bad state. Add a health check before the existing `startTracking()` call. Actually, since `endLunchBreak` already calls `startTracking()` directly, the health guard's restart would be redundant. Instead, wrap the existing `startTracking()` with better logging by adding a health check AFTER the lunch break DB update but BEFORE `startTracking()`:

In `endLunchBreak()`, add before the `startTracking()` call (around line 134):
```dart
// Log GPS health state before resuming tracking
await ensureGpsAlive(_ref, source: 'lunch_end');
```

Note: This will log the current state. The subsequent `startTracking()` call on line 135 will handle the actual restart. The ensureAlive check here serves primarily as a diagnostic log point — if the service was already dead before lunch, we'll see it in the logs. If it was alive, the startTracking will be a clean resume.

Add the import at the top:
```dart
import '../../tracking/providers/gps_health_guard_provider.dart';
```

**Step 2: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 3: Commit**

```bash
git add lib/features/shifts/providers/lunch_break_provider.dart
git commit -m "feat: add hard-gate GPS health check to lunch break end"
```

---

### Task 7: Create NavigatorObserver for soft nudge

**Files:**
- Create: `gps_tracker/lib/shared/widgets/gps_health_navigator_observer.dart`

**Step 1: Create the observer**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// NavigatorObserver that fires a soft GPS health nudge on every screen navigation.
/// Automatically catches all pushes, pops, and replacements without modifying screens.
class GpsHealthNavigatorObserver extends NavigatorObserver {
  final WidgetRef _ref;

  GpsHealthNavigatorObserver(this._ref);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    nudgeGps(_ref, source: 'navigation');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    nudgeGps(_ref, source: 'navigation');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    nudgeGps(_ref, source: 'navigation');
  }
}
```

**Important:** `nudgeGps` requires a `Ref`, but `NavigatorObserver` doesn't have one. We need `WidgetRef` from the widget that creates it. Since the `MaterialApp` is built in `_GpsTrackerAppState` which is a `ConsumerState`, we have access to `ref`.

**Step 2: Commit**

```bash
git add lib/shared/widgets/gps_health_navigator_observer.dart
git commit -m "feat: add NavigatorObserver for soft GPS health nudge on navigation"
```

---

### Task 8: Create Listener wrapper for dashboard interactions

**Files:**
- Create: `gps_tracker/lib/shared/widgets/gps_health_listener.dart`

**Step 1: Create the wrapper widget**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// Wraps a child widget with a Listener that fires a soft GPS health nudge
/// on any pointer-down event (tap, scroll start, etc.).
/// The 30-second debounce in GpsHealthGuard ensures this is lightweight.
class GpsHealthListener extends ConsumerWidget {
  final Widget child;

  const GpsHealthListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        nudgeGps(ref, source: 'dashboard_interaction');
      },
      child: child,
    );
  }
}
```

**Step 2: Commit**

```bash
git add lib/shared/widgets/gps_health_listener.dart
git commit -m "feat: add Listener wrapper for soft GPS health nudge on dashboard taps"
```

---

### Task 9: Integrate NavigatorObserver and Listener into app.dart

**Files:**
- Modify: `gps_tracker/lib/app.dart`

**Step 1: Add NavigatorObserver to MaterialApp**

In `_GpsTrackerAppState.build()`, find the `MaterialApp` widget (around line 349). Add `navigatorObservers`:

```dart
return MaterialApp(
  title: 'Tri-Logis Time',
  debugShowCheckedModeBanner: false,
  theme: TriLogisTheme.lightTheme,
  darkTheme: TriLogisTheme.darkTheme,
  themeMode: ThemeMode.system,
  navigatorObservers: [GpsHealthNavigatorObserver(ref)],
  home: authState.when(
    // ... existing code
  ),
);
```

**Step 2: Wrap HomeScreen with GpsHealthListener**

Find where `HomeScreen` is returned (around line 381 and 404). Wrap it:

```dart
// Line ~381: after phone check passes
return const GpsHealthListener(child: HomeScreen());
```

Same in `_PhoneCheckGate` (line ~404):
```dart
return GpsHealthListener(child: HomeScreen());
```

And the fail-open case (line ~410):
```dart
error: (_, __) => const GpsHealthListener(child: HomeScreen()),
```

Add imports at the top of app.dart:
```dart
import 'shared/widgets/gps_health_navigator_observer.dart';
import 'shared/widgets/gps_health_listener.dart';
```

**Step 3: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 4: Commit**

```bash
git add lib/app.dart
git commit -m "feat: integrate GPS health NavigatorObserver and Listener into app shell"
```

---

### Task 10: Remove old verifyTrackingHealth from TrackingNotifier

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

**Step 1: Keep the method but update it to use GpsHealthGuard internally**

The old `verifyTrackingHealth()` method (line 154) is still useful as a simpler API for the app-resume flow in `_refreshServiceState()`. But the direct callers (cleaning, maintenance) have been migrated to `ensureGpsAlive`. Update the method to also log via the health guard pattern:

Replace the existing `verifyTrackingHealth()` (lines 154-171) with:
```dart
  /// Public health check — call from app resume or other system events.
  /// User-interaction callers should use [ensureGpsAlive] from
  /// gps_health_guard_provider.dart instead (for structured logging).
  Future<void> verifyTrackingHealth() async {
    if (state.status == TrackingStatus.running ||
        state.status == TrackingStatus.starting) {
      return;
    }
    final shift = _ref.read(shiftProvider).activeShift;
    if (shift == null) return;

    final isRunning = await BackgroundTrackingService.isTracking;
    if (isRunning) return;

    _logger?.lifecycle(
      Severity.warn,
      'Tracking dead on app resume — restarting',
      metadata: {'shift_id': shift.id},
    );
    startTracking();
  }
```

This is a minimal change — just updating the comment and log message to distinguish app-resume from user-interaction checks.

**Step 2: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 3: Commit**

```bash
git add lib/features/tracking/providers/tracking_provider.dart
git commit -m "refactor: clarify verifyTrackingHealth for app-resume only, user actions use GpsHealthGuard"
```

---

### Task 11: Fix nudgeGps to accept both Ref and WidgetRef

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/gps_health_guard_provider.dart`
- Modify: `gps_tracker/lib/shared/widgets/gps_health_navigator_observer.dart`

**Step 1: Update convenience helpers to work with WidgetRef**

The `NavigatorObserver` and `GpsHealthListener` use `WidgetRef` but the helpers use `Ref`. Riverpod's `WidgetRef` can't be passed as `Ref`. Fix by making the helpers accept the providers directly instead:

Update `gps_health_guard_provider.dart` — replace the convenience functions:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/providers/shift_provider.dart';
import '../services/gps_health_guard.dart';
import 'tracking_provider.dart';

/// Singleton provider for the GPS health guard.
final gpsHealthGuardProvider = Provider<GpsHealthGuard>((ref) {
  return GpsHealthGuard();
});

/// Helper mixin to provide GPS health check convenience methods.
/// Works with both Ref (providers) and WidgetRef (widgets).
///
/// Usage from a provider (has Ref):
///   await ensureGpsAlive(_ref, source: 'cleaning_scan_in');
///
/// Usage from a widget (has WidgetRef):
///   nudgeGpsFromWidget(ref, source: 'navigation');
Future<HealthCheckResult> ensureGpsAlive(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  return guard.ensureAlive(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}

/// Soft nudge from a provider context (Ref).
void nudgeGps(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  guard.nudge(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}

/// Soft nudge from a widget context (WidgetRef).
void nudgeGpsFromWidget(WidgetRef ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  guard.nudge(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}
```

**Step 2: Update NavigatorObserver to use nudgeGpsFromWidget**

In `gps_health_navigator_observer.dart`, the observer stores the `WidgetRef` and calls `nudgeGpsFromWidget(ref, source: 'navigation')` instead of `nudgeGps`.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// NavigatorObserver that fires a soft GPS health nudge on every screen navigation.
class GpsHealthNavigatorObserver extends NavigatorObserver {
  final WidgetRef _ref;

  GpsHealthNavigatorObserver(this._ref);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }
}
```

**Step 3: Update GpsHealthListener to use nudgeGpsFromWidget**

In `gps_health_listener.dart`, change `nudgeGps` to `nudgeGpsFromWidget`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// Wraps a child widget with a Listener that fires a soft GPS health nudge
/// on any pointer-down event.
class GpsHealthListener extends ConsumerWidget {
  final Widget child;

  const GpsHealthListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        nudgeGpsFromWidget(ref, source: 'dashboard_interaction');
      },
      child: child,
    );
  }
}
```

**Step 4: Verify no regressions**

Run: `cd gps_tracker && flutter analyze`
Expected: No new warnings/errors

**Step 5: Commit**

```bash
git add lib/features/tracking/providers/gps_health_guard_provider.dart \
        lib/shared/widgets/gps_health_navigator_observer.dart \
        lib/shared/widgets/gps_health_listener.dart
git commit -m "fix: support both Ref and WidgetRef for GPS health nudge helpers"
```

---

### Task 12: Final verification

**Step 1: Run full analysis**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors, no new warnings

**Step 2: Run existing tests**

```bash
cd gps_tracker && flutter test
```
Expected: All existing tests pass (no behavior change for passing tests)

**Step 3: Manual verification checklist**

Verify these files were created:
- `lib/features/tracking/services/gps_health_guard.dart`
- `lib/features/tracking/providers/gps_health_guard_provider.dart`
- `lib/shared/widgets/gps_health_navigator_observer.dart`
- `lib/shared/widgets/gps_health_listener.dart`

Verify these files were modified (hard gate integration):
- `lib/features/cleaning/providers/cleaning_session_provider.dart` — `scanIn`, `scanOut` use `await ensureGpsAlive`
- `lib/features/maintenance/providers/maintenance_provider.dart` — `startSession`, `completeSession` use `await ensureGpsAlive`
- `lib/features/shifts/providers/shift_provider.dart` — `clockOut` uses `await ensureGpsAlive`
- `lib/features/shifts/providers/lunch_break_provider.dart` — `endLunchBreak` uses `await ensureGpsAlive`

Verify app.dart integration:
- `MaterialApp` has `navigatorObservers: [GpsHealthNavigatorObserver(ref)]`
- `HomeScreen` is wrapped in `GpsHealthListener`

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: GPS Health Guard — ensure tracking alive on every user interaction

Two-tier system:
- Hard gate (awaited): clock-out, QR scan in/out, maintenance start/complete, lunch end
- Soft nudge (fire-and-forget, 30s debounce): all navigation + dashboard taps

All checks logged to DiagnosticLogger with source, tier, duration, shift_id.
Resolves GPS data loss when employees interact with app while tracking is dead."
```
