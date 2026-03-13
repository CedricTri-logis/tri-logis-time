# Work Session Server-Required + Monitoring Visibility Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Work sessions (ménage/entretien/admin) require server confirmation before starting — like shift clock-in does. This forces the app to be awake and connected, ensuring reliable sync. The monitoring page shows the active session prominently.

**Architecture:** Change `WorkSessionService.startSession()` and `completeSession()` from local-first (return success even if RPC fails) to server-required (return error if RPC fails). Also wire work sessions into `SyncService.syncAll()` as a safety net for edge cases. Finally, reorder the monitoring UI.

**Tech Stack:** Dart/Flutter, Riverpod, SQLCipher, Supabase RPC, Next.js

---

## Chunk 1: Require server confirmation for sessions

### Task 1: Make startSession() require server confirmation

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_service.dart:168-223`

- [ ] **Step 1: Require server shift ID — fail if not resolved**

In `startSession()`, after the local insert (line 168) and the shift ID resolution loop (lines 170-178), change the fallback from success to error.

Replace lines 180-183:
```dart
    if (resolvedShiftId == null) {
      // Still no server shift ID — session stays pending, will sync later
      return WorkSessionResult.success(session);
    }
```

With:
```dart
    if (resolvedShiftId == null) {
      // Server shift not synced — cannot start session without server confirmation
      // Delete the local session since we're not going through with it
      await _localDb.deleteWorkSession(sessionId);
      return WorkSessionResult.error(
        'Connexion requise. Vérifiez votre connexion réseau et réessayez.',
      );
    }
```

- [ ] **Step 2: Require RPC success — fail if server rejects or network error**

Replace lines 215-223 (the two catch/fallback blocks that return success on failure):

```dart
      } else {
        // Server rejected — delete local session and return error
        final errorMsg = response['error'] as String? ?? 'Session refusée par le serveur';
        await _localDb.deleteWorkSession(sessionId);
        return WorkSessionResult.error(errorMsg);
      }
    } catch (e) {
      // Network error — delete local session and return error
      await _localDb.deleteWorkSession(sessionId);
      return WorkSessionResult.error(
        'Connexion requise. Vérifiez votre connexion réseau et réessayez.',
      );
    }
```

- [ ] **Step 3: Add deleteWorkSession to local DB**

In `gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart`, add after `markWorkSessionSyncError()`:

```dart
  /// Delete a work session from local DB (used when server confirmation fails).
  Future<void> deleteWorkSession(String sessionId) async {
    final db = await database;
    await db.delete(
      'local_work_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }
```

- [ ] **Step 4: Verify build**

Run: `cd gps_tracker && flutter analyze`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_service.dart \
       gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart
git commit -m "feat: require server confirmation for work session start — block if offline"
```

---

### Task 2: Make completeSession() require server confirmation

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_service.dart:226-348`

- [ ] **Step 1: Read the completeSession method**

Read lines 226-348 of `work_session_service.dart` to understand the current flow.

- [ ] **Step 2: Require RPC success for completion**

Find the section where the RPC `complete_work_session` is called and the error handling.
Change the pattern from "return success with warning on failure" to "return error on failure".

The local session should be updated to `completed` status locally (so the UI reflects it), but if the RPC fails, revert the local status back to `in_progress` and return an error:

After the RPC call, if it fails:
```dart
    } catch (e) {
      // Network error — revert local status back to in_progress
      await _localDb.updateWorkSessionStatus(
        session.id,
        WorkSessionStatus.inProgress,
      );
      return WorkSessionResult.error(
        'Connexion requise pour terminer la session. Vérifiez votre connexion réseau.',
      );
    }
```

- [ ] **Step 3: Add updateWorkSessionStatus to local DB**

In `work_session_local_db.dart`, add:

```dart
  /// Revert a work session status (used when server confirmation fails).
  Future<void> updateWorkSessionStatus(
    String sessionId,
    WorkSessionStatus status,
  ) async {
    final db = await database;
    await db.update(
      'local_work_sessions',
      {'status': status.toJson(), 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }
```

- [ ] **Step 4: Verify build**

Run: `cd gps_tracker && flutter analyze`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_service.dart \
       gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart
git commit -m "feat: require server confirmation for work session complete — block if offline"
```

---

### Task 3: Show connectivity error in the UI

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart`

- [ ] **Step 1: Read the provider's startSession and completeSession methods**

Read the `WorkSessionNotifier` class to understand how errors are surfaced to the UI.

- [ ] **Step 2: Ensure errors bubble up to SnackBar/dialog**

In `WorkSessionNotifier.startSession()`, the result should already be checked for errors. Verify that when `WorkSessionResult.error()` is returned, the UI shows a SnackBar with the error message. If the provider catches the error and silently ignores it, update it to propagate.

The pattern should be:
```dart
  Future<WorkSessionResult> startSession({...}) async {
    // ... existing code ...
    final result = await _service.startSession(...);

    if (!result.success) {
      // Error is returned to the caller (UI screen) which shows SnackBar
      return result;
    }

    // Update state with new active session
    state = state.copyWith(activeSession: result.session);
    return result;
  }
```

- [ ] **Step 3: Verify the UI screen shows errors**

Check the screen that calls `startSession()` (likely `shift_dashboard_screen.dart` or `session_start_sheet.dart`). Ensure it shows a SnackBar when the result is an error. Example:

```dart
final result = await ref.read(workSessionProvider.notifier).startSession(...);
if (!result.success) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(result.error ?? 'Erreur de connexion')),
  );
}
```

- [ ] **Step 4: Verify build**

Run: `cd gps_tracker && flutter analyze`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart
git commit -m "feat: surface session server errors to UI with connectivity message"
```

---

## Chunk 2: Safety net — wire into sync engine

### Task 4: Add work sessions to SyncService.syncAll() as backup

Even with server-required confirmation, edge cases can leave orphaned local sessions (network drops mid-response, app killed between local insert and RPC call). The sync engine cleans these up.

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart`
- Modify: `gps_tracker/lib/features/shifts/providers/sync_provider.dart`
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_service.dart`
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart`

- [ ] **Step 1: Add WorkSessionService injection to SyncService**

In `sync_service.dart`, add field and setter (after `_diagnosticSyncService`):

```dart
  WorkSessionService? _workSessionService;

  void setWorkSessionService(WorkSessionService service) {
    _workSessionService = service;
  }
```

Add import at top:
```dart
import '../../work_sessions/services/work_session_service.dart';
```

- [ ] **Step 2: Call syncPendingSessions in syncAll()**

In `syncAll()`, after `await _syncLunchBreaks();` (line 160), add:

```dart
    // Sync orphaned work sessions (safety net for mid-request failures)
    await _syncWorkSessions();
```

Add the private method:
```dart
  Future<void> _syncWorkSessions() async {
    final userId = _currentUserId;
    if (userId == null || _workSessionService == null) return;
    try {
      await _workSessionService!.syncPendingSessions(userId);
    } catch (_) {
      // Never let work session sync block the main sync
    }
  }
```

- [ ] **Step 3: Add getPendingCount to WorkSessionService and LocalDB**

In `work_session_local_db.dart`, add:
```dart
  Future<int> getPendingWorkSessionCount(String employeeId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM local_work_sessions WHERE employee_id = ? AND sync_status = ?',
      [employeeId, 'pending'],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
```

In `work_session_service.dart`, add:
```dart
  Future<int> getPendingCount(String employeeId) async {
    return _localDb.getPendingWorkSessionCount(employeeId);
  }
```

- [ ] **Step 4: Add work sessions to hasPendingData and getPendingCounts**

In `sync_service.dart`, update `hasPendingData()` — after diagnostics check, add:
```dart
    if (_workSessionService != null) {
      final count = await _workSessionService!.getPendingCount(userId);
      if (count > 0) return true;
    }
```

Update `getPendingCounts()` return type to include `workSessions`:
```dart
  Future<({int shifts, int gpsPoints, int diagnostics, int workSessions})> getPendingCounts() async {
    // ... existing code ...
    int pendingWorkSessionCount = 0;
    if (_workSessionService != null) {
      pendingWorkSessionCount = await _workSessionService!.getPendingCount(userId);
    }
    return (
      shifts: pendingShifts.length + errorShifts.length,
      gpsPoints: pendingGpsCount,
      diagnostics: pendingDiagnosticCount,
      workSessions: pendingWorkSessionCount,
    );
  }
```

- [ ] **Step 5: Wire injection in sync_provider.dart**

In `syncServiceProvider`, add after `setDiagnosticSyncService`:
```dart
  syncService.setWorkSessionService(ref.watch(workSessionServiceProvider));
```

Add import:
```dart
import '../../work_sessions/providers/work_session_provider.dart';
```

Update `SyncState` to include `pendingWorkSessions`:
- Add field: `final int pendingWorkSessions;`
- Add to constructor with default `0`
- Update `hasPendingData`: include `|| pendingWorkSessions > 0`
- Update `totalPending`: include `+ pendingWorkSessions`
- Add to `copyWith()`

Update `refreshPendingCounts` to destructure the new field:
```dart
    final (:shifts, :gpsPoints, :diagnostics, :workSessions) =
        await _syncService.getPendingCounts();
    state = state.copyWith(
      pendingShifts: shifts,
      pendingGpsPoints: gpsPoints,
      pendingDiagnostics: diagnostics,
      pendingWorkSessions: workSessions,
    );
```

- [ ] **Step 6: Verify build**

Run: `cd gps_tracker && flutter analyze`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/sync_service.dart \
       gps_tracker/lib/features/shifts/providers/sync_provider.dart \
       gps_tracker/lib/features/work_sessions/services/work_session_service.dart \
       gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart
git commit -m "feat: wire work sessions into SyncService.syncAll() as safety net for orphaned sessions"
```

---

## Chunk 3: Monitoring page UI reorder

### Task 5: Move session badge above clock-in location in team list

**Files:**
- Modify: `dashboard/src/components/monitoring/team-list.tsx:121-142`
- Modify: `dashboard/src/components/monitoring/google-team-map.tsx`
- Possibly modify: `dashboard/src/types/work-session.ts`

- [ ] **Step 1: Swap order — session badge above clock-in**

In `TeamListItem`, replace lines 121-142 with session badge FIRST, then clock-in:

```tsx
            {/* Active session info (cleaning, maintenance, admin) */}
            {isOnShift && employee.activeSessionType && (
              <SessionBadge
                sessionType={employee.activeSessionType}
                location={employee.activeSessionLocation}
                startedAt={employee.activeSessionStartedAt}
              />
            )}
            {/* Clock-in location */}
            {isOnShift && employee.currentShift?.clockInLocation && (
              <div className="flex items-center gap-1 text-xs text-blue-600 mt-0.5">
                <MapPin className="h-3 w-3 flex-shrink-0" />
                <span className="truncate">
                  {employee.currentShift.clockInLocationName
                    ? `Pointé à ${employee.currentShift.clockInLocationName}`
                    : `Pointé à ${employee.currentShift.clockInLocation.latitude.toFixed(4)}, ${employee.currentShift.clockInLocation.longitude.toFixed(4)}`
                  }
                </span>
              </div>
            )}
```

Note: condition changes from `employee.activeSessionLocation` to `employee.activeSessionType` so the badge shows even for admin sessions without a location.

- [ ] **Step 2: Update SessionBadge to show type label when no location**

```tsx
function SessionBadge({ sessionType, location, startedAt }: SessionBadgeProps) {
  const activityType: ActivityType = sessionType ?? 'cleaning';
  const config = ACTIVITY_TYPE_CONFIG[activityType];
  const Icon = ACTIVITY_TYPE_ICONS[activityType];

  return (
    <div
      className="flex items-center gap-1.5 text-xs mt-0.5"
      style={{ color: config.color }}
    >
      <Icon className="h-3 w-3 flex-shrink-0" />
      <span className="font-medium">{config.label}</span>
      {location && (
        <span className="truncate">— {location}</span>
      )}
      {startedAt && (
        <DurationCounter
          startTime={startedAt}
          format="hm"
          className="ml-1 flex-shrink-0 opacity-60"
        />
      )}
    </div>
  );
}
```

- [ ] **Step 3: Check ACTIVITY_TYPE_CONFIG has label field**

Read `dashboard/src/types/work-session.ts` and verify `ACTIVITY_TYPE_CONFIG` has a `label` field for each type. If missing, add:
```typescript
  cleaning: { label: 'Ménage', color: '#16a34a', ... },
  maintenance: { label: 'Entretien', color: '#2563eb', ... },
  admin: { label: 'Administration', color: '#7c3aed', ... },
```

- [ ] **Step 4: Reorder map popup to match**

In `google-team-map.tsx` `MarkerPopupContent`, move session row above GPS staleness:

```tsx
        {employee.activeSessionType && (
          <div className="flex items-center justify-between text-[11px]">
            <span className="text-slate-500">Session</span>
            <span className="font-semibold text-slate-700 truncate max-w-[120px]">
              {employee.activeSessionLocation ?? employee.activeSessionType}
            </span>
          </div>
        )}
```

- [ ] **Step 5: Build dashboard**

Run: `cd dashboard && npx next build`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/monitoring/team-list.tsx \
       dashboard/src/components/monitoring/google-team-map.tsx \
       dashboard/src/types/work-session.ts
git commit -m "feat: show active session type above clock-in location in monitoring page"
```
