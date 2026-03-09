# GPS Health Guard Design

Date: 2026-03-07
Status: Approved
Problem: GPS tracking dies silently while employees continue working (scanning QR codes, clocking in/out). No mechanism ties user interactions to GPS health verification.

## Problem Statement

Employees interact with the app (QR scans, maintenance sessions, lunch breaks) while GPS tracking is dead. Example: Fabiola clocked into studio 614 three minutes ago, but last GPS point was 20 minutes ago. The app has 6+ resilience layers for background recovery, but none are triggered by direct user interaction.

## Solution: Two-Tier GPS Health Guard

A singleton `GpsHealthGuard` that verifies GPS tracking health on every user interaction, with two modes:

### Tier 1 — Hard Gate (business-critical actions)

**Behavior:** Awaits GPS verification before action proceeds. If service is dead, restarts and waits up to 5 seconds. Action always proceeds regardless of result (never blocks work). Every check is logged.

**Actions (8 integration points):**

| Action | Provider Method | Source Tag |
|--------|----------------|------------|
| Clock-in shift | `ShiftNotifier.clockIn()` | `shift_clock_in` |
| Clock-out shift | `ShiftNotifier.clockOut()` | `shift_clock_out` |
| Scan QR in | `CleaningSessionNotifier.scanIn()` | `cleaning_scan_in` |
| Scan QR out | `CleaningSessionNotifier.scanOut()` | `cleaning_scan_out` |
| Manual QR entry | (same flow as scanIn/scanOut) | `cleaning_manual_entry` |
| Start maintenance | `MaintenanceNotifier.startSession()` | `maintenance_start` |
| Complete maintenance | `MaintenanceNotifier.completeSession()` | `maintenance_complete` |
| End lunch break | `LunchBreakNotifier.endLunchBreak()` | `lunch_end` |

**Integration pattern:**
```dart
final result = await ref.read(gpsHealthGuardProvider).ensureAlive(source: 'cleaning_scan_in');
// action continues regardless — log is already recorded
```

### Tier 2 — Soft Nudge (all other interactions)

**Behavior:** Non-blocking, fire-and-forget. Debounced to 30 seconds (max 2 checks/minute). Silently restarts GPS if dead. Every check is logged.

**Integration (automatic, zero screen modifications):**

| Mechanism | What It Catches | Source Tag |
|-----------|----------------|------------|
| `NavigatorObserver` on `MaterialApp` | All screen navigation | `navigation` |
| `Listener` widget on dashboard Scaffold | All taps/gestures in dashboard | `dashboard_interaction` |

## GpsHealthGuard API

```dart
class GpsHealthGuard {
  DateTime? _lastCheckAt;
  bool _isRestarting = false;  // mutex to prevent concurrent restarts

  /// HARD — called by business actions, awaits result
  Future<HealthCheckResult> ensureAlive({required String source}) async {
    // 1. Check FlutterForegroundTask.isRunningService
    // 2. If alive: log "health_check_ok", return ok
    // 3. If dead + no active shift: log "health_check_no_shift", return skipped
    // 4. If dead + active shift:
    //    a. Log "health_check_restart_attempt"
    //    b. Restart tracking (5s timeout)
    //    c. Log "health_check_restart_success" or "health_check_restart_failed"
    // 5. Update _lastCheckAt
    // 6. Return result (action proceeds regardless)
  }

  /// SOFT — called by general interactions, fire-and-forget
  void nudge({required String source}) {
    // If no active shift: return immediately
    // If <30s since last check: return immediately
    // Otherwise: fire-and-forget ensureAlive()
  }
}
```

## Diagnostic Logging

Every health check produces a diagnostic event via the existing `DiagnosticLogger`:

| Field | Values |
|-------|--------|
| `category` | `lifecycle` |
| `event` | `health_check_ok`, `health_check_restart_attempt`, `health_check_restart_success`, `health_check_restart_failed`, `health_check_no_shift` |
| `severity` | `info` (ok/no_shift), `warn` (restart attempt), `error` (restart failed) |
| `metadata.source` | Source tag from tables above |
| `metadata.service_was_alive` | `true`/`false` |
| `metadata.restart_duration_ms` | Duration if restart attempted |
| `metadata.shift_id` | Active shift ID |
| `metadata.time_since_last_check_s` | Seconds since previous check |
| `metadata.tier` | `hard` or `soft` |

Events sync to server via existing `DiagnosticSyncService` into `diagnostic_logs` table.

**Example log trail for a previously-broken scenario:**
```
08:00  health_check_ok              shift_clock_in         service_was_alive: true
08:15  health_check_ok              navigation             service_was_alive: true
08:35  health_check_restart_attempt cleaning_scan_in       service_was_alive: false
08:35  health_check_restart_success cleaning_scan_in       restart_duration_ms: 1200
08:38  health_check_ok              dashboard_interaction  service_was_alive: true
```

## Performance Impact

| Scenario | Cost |
|----------|------|
| Service alive (99% of checks) | ~1ms (boolean flag read) |
| Service dead, restart needed | 1-2s (one-time, only when problem exists) |
| Soft nudge debounced | 0ms (skipped entirely) |
| Max checks per minute | 2 (soft) + unlimited hard (but hard actions are infrequent) |

## Files to Create/Modify

### New Files
- `lib/features/tracking/services/gps_health_guard.dart` — GpsHealthGuard singleton
- `lib/features/tracking/providers/gps_health_guard_provider.dart` — Riverpod provider
- `lib/shared/widgets/gps_health_navigator_observer.dart` — NavigatorObserver for soft nudge
- `lib/shared/widgets/gps_health_listener.dart` — Listener wrapper for dashboard interactions

### Modified Files
- `lib/features/shifts/providers/shift_provider.dart` — Add hard gate to clockIn/clockOut
- `lib/features/cleaning/providers/cleaning_session_provider.dart` — Add hard gate to scanIn/scanOut
- `lib/features/maintenance/providers/maintenance_provider.dart` — Add hard gate to startSession/completeSession
- `lib/features/shifts/providers/lunch_break_provider.dart` — Add hard gate to endLunchBreak
- `lib/app.dart` — Register NavigatorObserver + wrap with Listener widget
