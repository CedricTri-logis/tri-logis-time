# Shift Reconciliation at Startup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** On app startup/login, reconcile local shift state with the server to recover orphaned shifts (app deleted/reinstalled while shift active) and clean up stale local shifts.

**Architecture:** Add a `reconcileWithServer()` method to `ShiftService` that queries the server for an active shift and compares with local state. Called from `_loadActiveShift()` in `ShiftNotifier` after local load. Fail-open: if server unreachable, keep local state as-is.

**Tech Stack:** Dart/Flutter, Supabase (existing `shifts` table query), SQLite (existing `local_shifts` table), flutter_riverpod.

---

## Reconciliation Logic

| Local | Server | Condition | Action |
|---|---|---|---|
| None | None | — | Nothing |
| Active | Active (same `serverId`) | — | Nothing (already synced) |
| None | Active | `clocked_in_at` is today (after last midnight ET) | **Resume**: insert local shift from server data |
| None | Active | `clocked_in_at` is before last midnight ET | **Close server shift**: update to `completed` |
| Active | None or Completed | — | **Close local shift**: mark as completed locally |

**Midnight reference:** `America/Montreal` timezone, consistent with pg_cron cleanup (migration 030).

---

### Task 1: Add `reconcileWithServer()` to `ShiftService`

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/shift_service.dart`

**Step 1: Add the reconciliation method**

After the existing `getActiveShift()` method (~line 303), add:

```dart
/// Reconcile local shift state with the server.
///
/// Handles scenarios where local and server state diverge:
/// - App reinstalled while shift active → resume server shift locally
/// - Server closed shift (midnight cleanup, admin) → close local shift
/// - Stale server shift (before last midnight) → close on server
///
/// Fail-open: if server is unreachable, returns local state unchanged.
Future<LocalShift?> reconcileShiftState() async {
  final userId = _currentUserId;
  if (userId == null) return null;

  // 1. Load local active shift
  final localShift = await _localDb.getActiveShift(userId);

  // 2. Query server for active shift (fail-open)
  Map<String, dynamic>? serverShift;
  try {
    serverShift = await _supabase
        .from('shifts')
        .select('id, employee_id, status, clocked_in_at, clock_in_location, clock_in_accuracy, created_at, updated_at')
        .eq('employee_id', userId)
        .eq('status', 'active')
        .maybeSingle();
  } catch (e) {
    debugPrint('[ShiftService] reconcile: server unreachable, keeping local state: $e');
    return localShift;
  }

  // 3. Both null → nothing to do
  if (localShift == null && serverShift == null) return null;

  // 4. Local active, server matches → already synced
  if (localShift != null && serverShift != null && localShift.serverId == serverShift['id']) {
    return localShift;
  }

  // 5. No local shift, server has active shift → resume or close
  if (localShift == null && serverShift != null) {
    final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
    final lastMidnight = _lastMidnightET();

    if (clockedInAt.isAfter(lastMidnight)) {
      // Recent shift — resume locally
      return await _resumeServerShift(userId, serverShift);
    } else {
      // Stale shift (before midnight) — close on server
      await _closeStaleServerShift(serverShift['id'] as String);
      return null;
    }
  }

  // 6. Local active, no server shift (or server completed) → close local
  if (localShift != null && serverShift == null) {
    await _localDb.updateShiftClockOut(
      shiftId: localShift.id,
      clockedOutAt: DateTime.now().toUtc(),
      reason: 'server_reconciliation',
    );
    await _localDb.markShiftSynced(localShift.id);
    return null;
  }

  // 7. Local active, server active but different shift → close local, handle server shift
  if (localShift != null && serverShift != null && localShift.serverId != serverShift['id']) {
    // Close the local orphan
    await _localDb.updateShiftClockOut(
      shiftId: localShift.id,
      clockedOutAt: DateTime.now().toUtc(),
      reason: 'server_reconciliation',
    );
    await _localDb.markShiftSynced(localShift.id);

    // Resume the server shift if recent
    final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
    final lastMidnight = _lastMidnightET();
    if (clockedInAt.isAfter(lastMidnight)) {
      return await _resumeServerShift(userId, serverShift);
    } else {
      await _closeStaleServerShift(serverShift['id'] as String);
      return null;
    }
  }

  return localShift;
}

/// Calculate last midnight in America/Montreal timezone (Eastern).
///
/// Uses UTC offset approximation: ET is UTC-5 (EST) or UTC-4 (EDT).
/// We use -5 as conservative default; a shift clocked in at 23:30 ET
/// will be correctly identified as "today" in both EST and EDT.
DateTime _lastMidnightET() {
  final now = DateTime.now().toUtc();
  // Eastern Time is UTC-5 (EST) or UTC-4 (EDT)
  // Convert UTC now to ET, truncate to midnight, convert back to UTC
  // Use -5 (EST) as conservative offset — worst case we resume a shift
  // that's slightly older, which is safer than closing a valid one
  const etOffset = Duration(hours: -5);
  final nowET = now.add(etOffset);
  final midnightET = DateTime(nowET.year, nowET.month, nowET.day);
  // Convert back to UTC
  return midnightET.subtract(etOffset);
}

/// Resume a server shift by creating a local copy.
Future<LocalShift> _resumeServerShift(String userId, Map<String, dynamic> serverShift) async {
  final serverId = serverShift['id'] as String;
  final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
  final now = DateTime.now().toUtc();

  // Parse clock-in location if available
  double? lat, lng;
  final locJson = serverShift['clock_in_location'];
  if (locJson is Map<String, dynamic>) {
    lat = (locJson['latitude'] as num?)?.toDouble();
    lng = (locJson['longitude'] as num?)?.toDouble();
  }
  final accuracy = (serverShift['clock_in_accuracy'] as num?)?.toDouble();

  final localShift = LocalShift(
    id: _uuid.v4(), // New local ID
    employeeId: userId,
    status: 'active',
    clockedInAt: clockedInAt,
    clockInLatitude: lat,
    clockInLongitude: lng,
    clockInAccuracy: accuracy,
    syncStatus: 'synced', // Already exists on server
    serverId: serverId,
    createdAt: now,
    updatedAt: now,
  );

  await _localDb.insertShift(localShift);
  debugPrint('[ShiftService] Resumed server shift $serverId locally as ${localShift.id}');
  return localShift;
}

/// Close a stale server shift (clocked in before last midnight).
Future<void> _closeStaleServerShift(String serverId) async {
  try {
    await _supabase
        .from('shifts')
        .update({
          'status': 'completed',
          'clocked_out_at': DateTime.now().toUtc().toIso8601String(),
          'clock_out_reason': 'stale_reconciliation',
        })
        .eq('id', serverId)
        .eq('status', 'active');
    debugPrint('[ShiftService] Closed stale server shift $serverId');
  } catch (e) {
    debugPrint('[ShiftService] Failed to close stale server shift $serverId: $e');
  }
}
```

**Step 2: Run `flutter analyze` on the file**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/services/shift_service.dart`
Expected: No new errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/shift_service.dart
git commit -m "feat: add shift reconciliation method to ShiftService"
```

---

### Task 2: Wire reconciliation into `_loadActiveShift()`

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

**Step 1: Update `_loadActiveShift()` to call reconciliation**

Replace the existing `_loadActiveShift()` method (lines 230-245):

```dart
/// Load the current active shift, reconciling with server state.
///
/// On first load after startup/login, queries the server to detect
/// orphaned shifts (app reinstalled, server-side closure missed).
/// Fail-open: if server unreachable, uses local state only.
Future<void> _loadActiveShift() async {
  state = state.copyWith(isLoading: true, clearError: true);
  try {
    final reconciledShift = await _shiftService.reconcileShiftState();
    final shift = reconciledShift?.toShift();

    if (shift != null) {
      _logger?.shift(Severity.info, 'Shift reconciled', metadata: {
        'shift_id': shift.id,
        'server_id': shift.serverId,
        'status': shift.status.toJson(),
      });
    }

    state = state.copyWith(
      activeShift: shift,
      isLoading: false,
      clearActiveShift: shift == null,
    );
  } catch (e) {
    _logger?.shift(Severity.error, 'Shift reconciliation failed', metadata: {
      'error': e.toString(),
    });
    // Fallback: load local state only
    try {
      final shift = await _shiftService.getActiveShift();
      state = state.copyWith(
        activeShift: shift,
        isLoading: false,
        clearActiveShift: shift == null,
      );
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load active shift',
      );
    }
  }
}
```

**Step 2: Run `flutter analyze`**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/providers/shift_provider.dart`
Expected: No new errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat: wire shift reconciliation into startup flow"
```

---

### Task 3: Add diagnostic logging to reconciliation

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/shift_service.dart`

**Step 1: Add diagnostic import and logging**

Add import at top of file:

```dart
import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
```

Add helper getter (similar to shift_provider.dart pattern):

```dart
DiagnosticLogger? get _logger =>
    DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;
```

Then add logging calls inside `reconcileShiftState()`:
- On resume: `_logger?.shift(Severity.info, 'Resumed orphaned server shift', metadata: {...})`
- On close stale: `_logger?.shift(Severity.warn, 'Closed stale server shift', metadata: {...})`
- On close local: `_logger?.shift(Severity.warn, 'Closed orphaned local shift', metadata: {...})`
- On server unreachable: `_logger?.shift(Severity.debug, 'Reconciliation skipped: server unreachable')`

**Step 2: Run `flutter analyze`**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/services/shift_service.dart`
Expected: No new errors

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/shift_service.dart
git commit -m "feat: add diagnostic logging to shift reconciliation"
```

---

### Task 4: Full build verification

**Step 1: Run full analysis**

Run: `cd gps_tracker && flutter analyze`
Expected: No new errors or warnings from our changes

**Step 2: Run existing tests**

Run: `cd gps_tracker && flutter test`
Expected: All existing tests pass (no regressions)

**Step 3: Final commit with all changes if any fixups needed**

```bash
git add -A
git commit -m "fix: address any analyzer issues from shift reconciliation"
```

---

## Manual Test Scenarios

After deployment, verify these scenarios:

1. **Normal startup** — Employee opens app with no active shift → nothing changes
2. **Normal resume** — Employee opens app with active local+server shift → nothing changes
3. **Reinstall recovery** — Delete app while shift active, reinstall, login → shift resumes
4. **Stale shift cleanup** — Delete app, wait past midnight, reinstall → server shift closed, fresh start
5. **Server closed** — Admin closes shift from dashboard, employee opens app → local shift cleaned up
6. **Offline** — Open app with no network → local state unchanged, no crash
