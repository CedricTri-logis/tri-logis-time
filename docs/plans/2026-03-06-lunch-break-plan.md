# Lunch Break Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let employees declare lunch breaks during active shifts, pausing GPS tracking, and auto-deducting lunch time from paid hours across the app and dashboard.

**Architecture:** New `lunch_breaks` table (Supabase + local SQLCipher). Flutter gets a lunch provider + pill button below the clock button. The `get_day_approval_detail` and `get_weekly_approval_summary` RPCs emit `lunch_start`/`lunch_end` timeline events and subtract lunch from total hours. Dashboard renders lunch rows in the clock indicator column with a utensils icon.

**Tech Stack:** Flutter/Dart (Riverpod, SQLCipher, Supabase), PostgreSQL (Supabase migrations), Next.js/TypeScript (dashboard)

---

## Task 1: Supabase Migration — `lunch_breaks` Table + RLS

**Files:**
- Create: `supabase/migrations/134_lunch_breaks.sql`

**Step 1: Write the migration**

```sql
-- Create lunch_breaks table
CREATE TABLE lunch_breaks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_lunch_breaks_shift_id ON lunch_breaks(shift_id);
CREATE INDEX idx_lunch_breaks_employee_date ON lunch_breaks(employee_id, started_at DESC);

-- RLS
ALTER TABLE lunch_breaks ENABLE ROW LEVEL SECURITY;

-- Employees can view their own lunch breaks
CREATE POLICY "Employees can view own lunch breaks"
    ON lunch_breaks FOR SELECT
    USING (employee_id = auth.uid());

-- Employees can insert their own lunch breaks
CREATE POLICY "Employees can insert own lunch breaks"
    ON lunch_breaks FOR INSERT
    WITH CHECK (employee_id = auth.uid());

-- Employees can update their own lunch breaks (to set ended_at)
CREATE POLICY "Employees can update own lunch breaks"
    ON lunch_breaks FOR UPDATE
    USING (employee_id = auth.uid());

-- Supervisors can view their employees' lunch breaks
CREATE POLICY "Supervisors can view employee lunch breaks"
    ON lunch_breaks FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE supervisor_id = auth.uid()
            AND employee_id = lunch_breaks.employee_id
        )
    );

-- Admins can do everything
CREATE POLICY "Admins have full access to lunch breaks"
    ON lunch_breaks FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE id = auth.uid() AND role = 'admin'
        )
    );
```

**Step 2: Apply migration**

Run via Supabase MCP `apply_migration` or:
```bash
cd supabase && supabase db push
```

**Step 3: Commit**

```bash
git add supabase/migrations/134_lunch_breaks.sql
git commit -m "feat: add lunch_breaks table with RLS policies"
```

---

## Task 2: Supabase Migration — Update `get_day_approval_detail` RPC

**Files:**
- Create: `supabase/migrations/135_lunch_in_approval_detail.sql`

This migration replaces the `get_day_approval_detail` function to add:
1. Two new UNION stages: `lunch_start` and `lunch_end` activity types
2. Lunch breaks as covered periods in gap detection (so they don't generate untracked gaps)
3. `lunch_minutes` in the summary calculation
4. `total_shift_minutes` reduced by lunch duration

**Step 1: Write the migration**

The migration must `CREATE OR REPLACE FUNCTION get_day_approval_detail(...)`. Copy the existing function from migration 131 and add:

**A) After the `gap` UNION ALL block, add lunch_start UNION:**

```sql
-- LUNCH START events
UNION ALL
SELECT
    'lunch_start'::TEXT AS activity_type,
    lb.id AS activity_id,
    s.id AS shift_id,
    lb.started_at,
    lb.started_at AS ended_at,
    0 AS duration_minutes,
    'approved'::TEXT AS auto_status,
    'Pause diner'::TEXT AS auto_reason,
    NULL::UUID AS matched_location_id,
    NULL::TEXT AS location_name,
    NULL::TEXT AS location_type,
    NULL::DECIMAL AS latitude,
    NULL::DECIMAL AS longitude,
    NULL::DECIMAL AS distance_km,
    NULL::DECIMAL AS road_distance_km,
    NULL::TEXT AS transport_mode,
    NULL::BOOLEAN AS has_gps_gap,
    NULL::UUID AS start_location_id,
    NULL::TEXT AS start_location_name,
    NULL::TEXT AS start_location_type,
    NULL::UUID AS end_location_id,
    NULL::TEXT AS end_location_name,
    NULL::TEXT AS end_location_type,
    0 AS gps_gap_seconds,
    0 AS gps_gap_count
FROM lunch_breaks lb
JOIN shifts s ON s.id = lb.shift_id
WHERE lb.employee_id = p_employee_id
  AND lb.started_at >= (p_date AT TIME ZONE 'America/Toronto')
  AND lb.started_at < ((p_date + 1) AT TIME ZONE 'America/Toronto')

-- LUNCH END events
UNION ALL
SELECT
    'lunch_end'::TEXT AS activity_type,
    lb.id AS activity_id,
    s.id AS shift_id,
    lb.ended_at AS started_at,
    lb.ended_at AS ended_at,
    EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60 AS duration_minutes,
    'approved'::TEXT AS auto_status,
    'Pause diner'::TEXT AS auto_reason,
    NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::DECIMAL, NULL::DECIMAL,
    NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
    NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::UUID, NULL::TEXT, NULL::TEXT,
    0, 0
FROM lunch_breaks lb
JOIN shifts s ON s.id = lb.shift_id
WHERE lb.employee_id = p_employee_id
  AND lb.ended_at IS NOT NULL
  AND lb.started_at >= (p_date AT TIME ZONE 'America/Toronto')
  AND lb.started_at < ((p_date + 1) AT TIME ZONE 'America/Toronto')
```

**B) In the gap detection timeline builder, add lunch breaks as covered events:**

After the existing activities CTE (stops + trips), add:
```sql
-- Include lunch breaks as covered periods
UNION ALL
SELECT lb.started_at AS event_start, lb.ended_at AS event_end
FROM lunch_breaks lb
WHERE lb.shift_id = ANY(v_shift_ids)
  AND lb.ended_at IS NOT NULL
```

**C) In the summary calculation, add lunch_minutes:**

```sql
-- Calculate lunch minutes
v_lunch_minutes := COALESCE((
    SELECT SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60)
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.ended_at IS NOT NULL
      AND lb.started_at >= (p_date AT TIME ZONE 'America/Toronto')
      AND lb.started_at < ((p_date + 1) AT TIME ZONE 'America/Toronto')
), 0);

-- Subtract lunch from total
v_total_shift_minutes := v_total_shift_minutes - v_lunch_minutes;
```

**D) Add `lunch_minutes` to the returned JSONB summary:**

```sql
'lunch_minutes', v_lunch_minutes
```

**Step 2: Apply migration**

Run via Supabase MCP.

**Step 3: Commit**

```bash
git add supabase/migrations/135_lunch_in_approval_detail.sql
git commit -m "feat: add lunch_start/lunch_end to get_day_approval_detail RPC"
```

---

## Task 3: Supabase Migration — Update `get_weekly_approval_summary` RPC

**Files:**
- Create: `supabase/migrations/136_lunch_in_weekly_summary.sql`

**Step 1: Write the migration**

Update `get_weekly_approval_summary` to:
1. Add `lunch_minutes` to each day entry
2. Subtract lunch minutes from `total_shift_minutes`

In the day stats calculation, add:
```sql
COALESCE((
    SELECT SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60)
    FROM lunch_breaks lb
    WHERE lb.employee_id = ep.id
      AND lb.ended_at IS NOT NULL
      AND lb.started_at >= (v_day AT TIME ZONE 'America/Toronto')
      AND lb.started_at < ((v_day + 1) AT TIME ZONE 'America/Toronto')
), 0) AS lunch_minutes
```

And include it in the JSONB output, subtracting from total_shift_minutes.

**Step 2: Apply and commit**

```bash
git add supabase/migrations/136_lunch_in_weekly_summary.sql
git commit -m "feat: add lunch_minutes to get_weekly_approval_summary RPC"
```

---

## Task 4: Flutter — Local Database Schema (SQLCipher)

**Files:**
- Modify: `gps_tracker/lib/shared/services/local_database.dart`

**Step 1: Bump database version**

At line 27, change:
```dart
static const int _databaseVersion = 7; // was 6
```

**Step 2: Add `_createLunchBreaksTable` method**

After `_createDiagnosticEventsTable` (around line 399), add:

```dart
/// Create lunch breaks table for offline-first lunch tracking.
Future<void> _createLunchBreaksTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_lunch_breaks (
      id TEXT PRIMARY KEY,
      shift_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
      server_id TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_local_lunch_breaks_shift ON local_lunch_breaks(shift_id)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_local_lunch_breaks_sync ON local_lunch_breaks(sync_status)
  ''');
}
```

**Step 3: Call it in `_onCreate`**

In `_onCreate` (line 186), after `_createDiagnosticEventsTable(db);` (line 262), add:
```dart
// Create lunch breaks table
await _createLunchBreaksTable(db);
```

**Step 4: Add upgrade path in `_onUpgrade`**

In the `_onUpgrade` method, add a case for version 7:
```dart
if (oldVersion < 7) {
  await _createLunchBreaksTable(db);
}
```

**Step 5: Add CRUD methods**

Add after the diagnostic event methods:

```dart
/// Insert a new lunch break record.
Future<void> insertLunchBreak({
  required String id,
  required String shiftId,
  required String employeeId,
  required DateTime startedAt,
}) async {
  final db = _database;
  if (db == null) throw LocalDatabaseException('Database not initialized', operation: 'insertLunchBreak');
  await db.insert('local_lunch_breaks', {
    'id': id,
    'shift_id': shiftId,
    'employee_id': employeeId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'sync_status': 'pending',
    'created_at': DateTime.now().toUtc().toIso8601String(),
  });
}

/// End a lunch break by setting ended_at.
Future<void> endLunchBreak(String id, DateTime endedAt) async {
  final db = _database;
  if (db == null) throw LocalDatabaseException('Database not initialized', operation: 'endLunchBreak');
  await db.update(
    'local_lunch_breaks',
    {'ended_at': endedAt.toUtc().toIso8601String()},
    where: 'id = ?',
    whereArgs: [id],
  );
}

/// Get the active (open) lunch break for a shift.
Future<Map<String, dynamic>?> getActiveLunchBreak(String shiftId) async {
  final db = _database;
  if (db == null) return null;
  final results = await db.query(
    'local_lunch_breaks',
    where: 'shift_id = ? AND ended_at IS NULL',
    whereArgs: [shiftId],
    limit: 1,
  );
  return results.isEmpty ? null : results.first;
}

/// Get all lunch breaks for a shift.
Future<List<Map<String, dynamic>>> getLunchBreaksForShift(String shiftId) async {
  final db = _database;
  if (db == null) return [];
  return db.query(
    'local_lunch_breaks',
    where: 'shift_id = ?',
    whereArgs: [shiftId],
    orderBy: 'started_at ASC',
  );
}

/// Get pending (unsynced) lunch breaks.
Future<List<Map<String, dynamic>>> getPendingLunchBreaks() async {
  final db = _database;
  if (db == null) return [];
  return db.query(
    'local_lunch_breaks',
    where: 'sync_status = ? AND ended_at IS NOT NULL',
    whereArgs: ['pending'],
  );
}

/// Mark a lunch break as synced.
Future<void> markLunchBreakSynced(String id, String serverId) async {
  final db = _database;
  if (db == null) return;
  await db.update(
    'local_lunch_breaks',
    {'sync_status': 'synced', 'server_id': serverId},
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

**Step 6: Commit**

```bash
git add gps_tracker/lib/shared/services/local_database.dart
git commit -m "feat: add local_lunch_breaks table to SQLCipher database"
```

---

## Task 5: Flutter — Lunch Break Model

**Files:**
- Create: `gps_tracker/lib/features/shifts/models/lunch_break.dart`

**Step 1: Create the model**

```dart
import 'shift_enums.dart';

/// A lunch break within a shift.
class LunchBreak {
  final String id;
  final String shiftId;
  final String employeeId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final SyncStatus syncStatus;
  final String? serverId;
  final DateTime createdAt;

  const LunchBreak({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.startedAt,
    this.endedAt,
    this.syncStatus = SyncStatus.pending,
    this.serverId,
    required this.createdAt,
  });

  bool get isActive => endedAt == null;

  Duration? get duration =>
      endedAt != null ? endedAt!.difference(startedAt) : null;

  factory LunchBreak.fromMap(Map<String, dynamic> map) {
    return LunchBreak(
      id: map['id'] as String,
      shiftId: map['shift_id'] as String,
      employeeId: map['employee_id'] as String,
      startedAt: DateTime.parse(map['started_at'] as String),
      endedAt: map['ended_at'] != null
          ? DateTime.parse(map['ended_at'] as String)
          : null,
      syncStatus: SyncStatus.fromJson(map['sync_status'] as String? ?? 'pending'),
      serverId: map['server_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'shift_id': shiftId,
      'employee_id': employeeId,
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt?.toUtc().toIso8601String(),
      'sync_status': syncStatus.toJson(),
      'server_id': serverId,
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  LunchBreak copyWith({
    DateTime? endedAt,
    SyncStatus? syncStatus,
    String? serverId,
  }) {
    return LunchBreak(
      id: id,
      shiftId: shiftId,
      employeeId: employeeId,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      syncStatus: syncStatus ?? this.syncStatus,
      serverId: serverId ?? this.serverId,
      createdAt: createdAt,
    );
  }
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/models/lunch_break.dart
git commit -m "feat: add LunchBreak model"
```

---

## Task 6: Flutter — Lunch Break Provider

**Files:**
- Create: `gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart`

**Step 1: Create the provider**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/services/local_database.dart';
import '../../tracking/providers/tracking_provider.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../models/lunch_break.dart';
import 'shift_provider.dart';

/// State for lunch break operations.
class LunchBreakState {
  final LunchBreak? activeLunchBreak;
  final bool isStarting;
  final bool isEnding;
  final String? error;

  const LunchBreakState({
    this.activeLunchBreak,
    this.isStarting = false,
    this.isEnding = false,
    this.error,
  });

  bool get isOnLunch => activeLunchBreak != null;

  LunchBreakState copyWith({
    LunchBreak? activeLunchBreak,
    bool? isStarting,
    bool? isEnding,
    String? error,
    bool clearActiveLunchBreak = false,
    bool clearError = false,
  }) {
    return LunchBreakState(
      activeLunchBreak: clearActiveLunchBreak ? null : (activeLunchBreak ?? this.activeLunchBreak),
      isStarting: isStarting ?? this.isStarting,
      isEnding: isEnding ?? this.isEnding,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier for managing lunch break state.
class LunchBreakNotifier extends StateNotifier<LunchBreakState> {
  final Ref _ref;
  final LocalDatabase _localDb;

  LunchBreakNotifier(this._ref, this._localDb) : super(const LunchBreakState()) {
    _init();
  }

  Future<void> _init() async {
    // Check for any open lunch break from a previous session
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null) return;

    final openBreak = await _localDb.getActiveLunchBreak(shift.id);
    if (openBreak != null) {
      state = state.copyWith(activeLunchBreak: LunchBreak.fromMap(openBreak));
    }
  }

  /// Start a lunch break for the active shift.
  Future<void> startLunchBreak() async {
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null || state.isOnLunch) return;

    state = state.copyWith(isStarting: true, clearError: true);

    try {
      final id = const Uuid().v4();
      final now = DateTime.now().toUtc();

      await _localDb.insertLunchBreak(
        id: id,
        shiftId: shift.id,
        employeeId: shift.employeeId,
        startedAt: now,
      );

      final lunchBreak = LunchBreak(
        id: id,
        shiftId: shift.id,
        employeeId: shift.employeeId,
        startedAt: now,
        createdAt: now,
      );

      state = state.copyWith(
        activeLunchBreak: lunchBreak,
        isStarting: false,
      );

      // Stop GPS tracking
      await _ref.read(trackingProvider.notifier).stopTracking(reason: 'lunch_break');

      // Update iOS Live Activity
      ShiftActivityService.instance.updateStatus('lunch');
    } catch (e) {
      state = state.copyWith(
        isStarting: false,
        error: 'Erreur: ${e.toString()}',
      );
    }
  }

  /// End the current lunch break.
  Future<void> endLunchBreak() async {
    final lunchBreak = state.activeLunchBreak;
    if (lunchBreak == null) return;

    state = state.copyWith(isEnding: true, clearError: true);

    try {
      final now = DateTime.now().toUtc();

      await _localDb.endLunchBreak(lunchBreak.id, now);

      state = state.copyWith(
        clearActiveLunchBreak: true,
        isEnding: false,
      );

      // Resume GPS tracking
      await _ref.read(trackingProvider.notifier).startTracking();

      // Update iOS Live Activity back to active
      ShiftActivityService.instance.updateStatus('active');

      // Trigger sync of the completed lunch break
      _ref.read(syncProvider.notifier).notifyPendingData();
    } catch (e) {
      state = state.copyWith(
        isEnding: false,
        error: 'Erreur: ${e.toString()}',
      );
    }
  }

  /// Clear lunch state when shift ends.
  void clearOnShiftEnd() {
    state = const LunchBreakState();
  }
}

/// Provider for lunch break state.
final lunchBreakProvider =
    StateNotifierProvider<LunchBreakNotifier, LunchBreakState>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return LunchBreakNotifier(ref, localDb);
});

/// Convenience provider for isOnLunch.
final isOnLunchProvider = Provider<bool>((ref) {
  return ref.watch(lunchBreakProvider).isOnLunch;
});
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart
git commit -m "feat: add lunch break provider with start/end/sync logic"
```

---

## Task 7: Flutter — Lunch Break Button Widget

**Files:**
- Create: `gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart`

**Step 1: Create the widget**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/lunch_break_provider.dart';
import '../providers/shift_provider.dart';

/// Compact pill button for starting/ending lunch breaks.
/// Visible only when a shift is active.
class LunchBreakButton extends ConsumerWidget {
  const LunchBreakButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftState = ref.watch(shiftProvider);
    final lunchState = ref.watch(lunchBreakProvider);
    final hasActiveShift = shiftState.activeShift != null;

    if (!hasActiveShift) return const SizedBox.shrink();

    final isOnLunch = lunchState.isOnLunch;
    final isLoading = lunchState.isStarting || lunchState.isEnding;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: ElevatedButton.icon(
            onPressed: isLoading
                ? null
                : () {
                    if (isOnLunch) {
                      ref.read(lunchBreakProvider.notifier).endLunchBreak();
                    } else {
                      ref.read(lunchBreakProvider.notifier).startLunchBreak();
                    }
                  },
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    isOnLunch ? Icons.restaurant : Icons.restaurant_outlined,
                    size: 20,
                  ),
            label: Text(
              isOnLunch ? 'FIN PAUSE' : 'PAUSE DINER',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                fontSize: 14,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isOnLunch
                  ? Colors.green.shade600
                  : Colors.orange.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              elevation: 3,
            ),
          ),
        ),
      ),
    );
  }
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart
git commit -m "feat: add LunchBreakButton pill widget"
```

---

## Task 8: Flutter — Integrate Lunch Button into Dashboard Screen

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/clock_button.dart`

**Step 1: Add lunch import and button to shift_dashboard_screen.dart**

Add import at the top (after line 52):
```dart
import '../providers/lunch_break_provider.dart';
import '../widgets/lunch_break_button.dart';
```

At line 1376, where the ClockButton is rendered, modify the Column to include the lunch button and disable the clock button during lunch:

```dart
Center(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClockButton(
        onClockIn: _handleClockIn,
        onClockOut: _handleClockOut,
        isExternallyLoading: _isClockInPreparing,
        isDisabled: ref.watch(isOnLunchProvider),
      ),
      const ClockButtonSettingsWarning(),
      const SizedBox(height: 16),
      const LunchBreakButton(),
    ],
  ),
),
```

**Step 2: Modify ClockButton to accept `isDisabled`**

In `clock_button.dart`, add the parameter (after line 11):

```dart
final bool isDisabled;
```

Update constructor (line 13-18):
```dart
const ClockButton({
  super.key,
  this.onClockIn,
  this.onClockOut,
  this.isExternallyLoading = false,
  this.isDisabled = false,
});
```

Update the onPressed logic (line 43-51) — add `isDisabled` to the null check:
```dart
onPressed: isLoading || isDisabled
    ? null
    : () {
        if (hasActiveShift) {
          onClockOut?.call();
        } else {
          onClockIn?.call();
        }
      },
```

Add visual dimming when disabled during lunch — wrap the Container in an Opacity (or adjust the alpha of the shadow):
```dart
return Opacity(
  opacity: isDisabled ? 0.5 : 1.0,
  child: Container(
    // ... existing container code
  ),
);
```

**Step 3: Clear lunch state on clock-out**

In `shift_provider.dart`, in the `clockOut()` method, after stopping tracking and before the final state update, add:
```dart
ref.read(lunchBreakProvider.notifier).clearOnShiftEnd();
```

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart \
       gps_tracker/lib/features/shifts/widgets/clock_button.dart \
       gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat: integrate lunch button below clock button, disable clock during lunch"
```

---

## Task 9: Flutter — Lunch Break Sync

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/sync_provider.dart`

**Step 1: Add lunch break sync to the sync cycle**

In the `syncPendingData()` method (or equivalent), add a step to sync pending lunch breaks. Follow the same pattern used for GPS points:

```dart
// Sync pending lunch breaks
final pendingLunchBreaks = await _localDb.getPendingLunchBreaks();
for (final breakMap in pendingLunchBreaks) {
  try {
    final result = await _supabase.from('lunch_breaks').upsert({
      'id': breakMap['id'],
      'shift_id': breakMap['shift_id'],
      'employee_id': breakMap['employee_id'],
      'started_at': breakMap['started_at'],
      'ended_at': breakMap['ended_at'],
    }, onConflict: 'id').select().single();

    await _localDb.markLunchBreakSynced(
      breakMap['id'] as String,
      result['id'] as String,
    );
  } catch (e) {
    debugPrint('[Sync] Failed to sync lunch break: $e');
  }
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/sync_provider.dart
git commit -m "feat: sync lunch breaks to Supabase during sync cycle"
```

---

## Task 10: Flutter — iOS Live Activity Lunch State

**Files:**
- Modify: `gps_tracker/lib/shared/services/shift_activity_service.dart`

**Step 1: Handle 'lunch' status**

In the `updateStatus` method, ensure the `'lunch'` status value is passed through to the native iOS channel. The native Swift side will need to display "En pause diner" text. If the status mapping is a simple string passthrough, this may already work. If not, add the mapping.

The existing method signature is `updateStatus(String status)` where status is one of `'active'`, `'gps_lost'`. Add `'lunch'` as a recognized value.

On the Swift side (if Live Activity is implemented), update the widget to show a lunch icon/text when status is `'lunch'`.

**Step 2: Commit**

```bash
git add gps_tracker/lib/shared/services/shift_activity_service.dart
git commit -m "feat: add lunch status to iOS Live Activity"
```

---

## Task 11: Dashboard — TypeScript Types

**Files:**
- Modify: `dashboard/src/types/mileage.ts`

**Step 1: Update ApprovalActivity type (line 230)**

Change:
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap';
```
To:
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch_start' | 'lunch_end';
```

**Step 2: Update DayApprovalDetail summary (line 269-274)**

Add `lunch_minutes`:
```typescript
summary: {
  total_shift_minutes: number;
  approved_minutes: number;
  rejected_minutes: number;
  needs_review_count: number;
  lunch_minutes: number;
};
```

**Step 3: Update WeeklyDayEntry (line 277-286)**

Add `lunch_minutes`:
```typescript
export interface WeeklyDayEntry {
  date: string;
  has_shifts: boolean;
  has_active_shift: boolean;
  status: DayApprovalStatus;
  total_shift_minutes: number;
  approved_minutes: number | null;
  rejected_minutes: number | null;
  needs_review_count: number;
  lunch_minutes: number;
}
```

**Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add lunch_start/lunch_end to TypeScript approval types"
```

---

## Task 12: Dashboard — Update `merge-clock-events.ts`

**Files:**
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts`

**Step 1: Update MergeableActivity type (line 9)**

Change:
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap';
```
To:
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch_start' | 'lunch_end';
```

**Step 2: Add ProcessedActivity lunch flags (line 15-19)**

Add:
```typescript
export interface ProcessedActivity<T extends MergeableActivity> {
  item: T;
  hasClockIn?: boolean;
  hasClockOut?: boolean;
  hasLunchStart?: boolean;
  hasLunchEnd?: boolean;
}
```

**Step 3: Handle lunch events in the merge logic**

In the filter at line 69-74, also pass through lunch events (they should not be filtered as micro-shifts):
```typescript
const filtered = items.filter((item, idx) => {
  if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') return true;
  // ... existing logic
});
```
Lunch events (`lunch_start`, `lunch_end`) already pass through since they're not `clock_in`/`clock_out`. No change needed for filtering.

In the merge step (line 83-102), add lunch merging into stops:
```typescript
for (let i = 0; i < filtered.length; i++) {
  const item = filtered[i];
  if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out'
      && item.activity_type !== 'lunch_start' && item.activity_type !== 'lunch_end') continue;

  const clockTime = new Date(item.started_at).getTime();

  for (let j = 0; j < filtered.length; j++) {
    if (filtered[j].activity_type !== 'stop' && filtered[j].activity_type !== 'gap') continue;
    const stopStart = new Date(filtered[j].started_at).getTime();
    const stopEnd = new Date(filtered[j].ended_at).getTime();
    if (clockTime >= (stopStart - MERGE_TOLERANCE_MS) && clockTime <= (stopEnd + MERGE_TOLERANCE_MS)) {
      mergedIndices.add(i);
      const existing = clockFlags.get(j) || {};
      if (item.activity_type === 'clock_in') existing.clockIn = true;
      if (item.activity_type === 'clock_out') existing.clockOut = true;
      if (item.activity_type === 'lunch_start') existing.lunchStart = true;
      if (item.activity_type === 'lunch_end') existing.lunchEnd = true;
      clockFlags.set(j, existing);
      break;
    }
  }
}
```

Update the result builder to include lunch flags:
```typescript
result.push({
  item: filtered[i],
  hasClockIn: flags?.clockIn,
  hasClockOut: flags?.clockOut,
  hasLunchStart: flags?.lunchStart,
  hasLunchEnd: flags?.lunchEnd,
});
```

**Step 4: Commit**

```bash
git add dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat: add lunch event merging to merge-clock-events"
```

---

## Task 13: Dashboard — Update `day-approval-detail.tsx`

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Add Utensils import**

At the lucide-react import (top of file), add `UtensilsCrossed`:
```typescript
import {
  // ... existing imports
  UtensilsCrossed,
} from 'lucide-react';
```

**Step 2: Update `ApprovalActivityIcon` (line 88-111)**

Add lunch case before the trip check:
```typescript
function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
  if (activity.activity_type === 'lunch_start' || activity.activity_type === 'lunch_end') {
    return <UtensilsCrossed className="h-4 w-4 text-orange-500" />;
  }
  if (activity.activity_type === 'gap') {
    // ... existing code
```

**Step 3: Update type guards in `ActivityRow` (line 869-872)**

Add:
```typescript
const isLunch = activity.activity_type === 'lunch_start' || activity.activity_type === 'lunch_end';
```

**Step 4: Update the Action column (line 920-980)**

For lunch rows, show no approve/reject buttons — just a neutral badge:
```typescript
{/* Action / Approbation */}
<td className="px-3 py-3 text-center">
  {isLunch ? (
    <div className="flex justify-center">
      <Badge variant="outline" className="font-bold text-[10px] px-2.5 py-0.5 rounded-full bg-slate-100 text-slate-600 border-slate-200">
        <UtensilsCrossed className="h-3 w-3 mr-1" />
        Pause
      </Badge>
    </div>
  ) : !isApproved ? (
    // ... existing approve/reject buttons
```

**Step 5: Update the Clock indicator column (line 982-990)**

Add lunch icons:
```typescript
{/* Clock-in/out / lunch indicator */}
<td className="px-2 py-3 text-center">
  <div className="flex items-center justify-center gap-0.5">
    {hasClockIn && <span title="Debut de quart"><LogIn className="h-3.5 w-3.5 text-emerald-600" /></span>}
    {hasClockOut && <span title="Fin de quart"><LogOut className="h-3.5 w-3.5 text-red-600" /></span>}
    {hasLunchStart && <span title="Debut pause diner"><UtensilsCrossed className="h-3.5 w-3.5 text-orange-500" /></span>}
    {hasLunchEnd && <span title="Fin pause diner"><UtensilsCrossed className="h-3.5 w-3.5 text-green-600" /></span>}
    {isClock && activity.activity_type === 'clock_in' && <LogIn className="h-3.5 w-3.5 text-emerald-600" />}
    {isClock && activity.activity_type === 'clock_out' && <LogOut className="h-3.5 w-3.5 text-red-600" />}
    {isLunch && activity.activity_type === 'lunch_start' && <UtensilsCrossed className="h-3.5 w-3.5 text-orange-500" />}
    {isLunch && activity.activity_type === 'lunch_end' && <UtensilsCrossed className="h-3.5 w-3.5 text-green-600" />}
  </div>
</td>
```

**Step 6: Update Duration column (line 1000-1021)**

For lunch, show duration only on `lunch_end`:
```typescript
{(isClock || (isLunch && activity.activity_type === 'lunch_start')) ? '—' : formatDurationMinutes(activity.duration_minutes)}
```

**Step 7: Update Details column (line 1023-1071)**

Add lunch case after the gap case:
```typescript
) : isLunch ? (
  <div className="space-y-1">
    <div className={`text-xs flex items-center gap-1.5 text-slate-700 font-medium`}>
      <UtensilsCrossed className="h-3 w-3" />
      <span className="font-bold">
        {activity.activity_type === 'lunch_start' ? 'Debut pause diner' : 'Fin pause diner'}
      </span>
    </div>
  </div>
) : isStop ? (
```

**Step 8: Update row styling**

For lunch rows, use neutral slate styling instead of the status-based coloring. In `statusConfig`, lunch activities have `auto_status: 'approved'`, so they'd normally get green. Override this in the row className:
```typescript
<tr
  className={`${isLunch ? 'bg-slate-50/80 border-l-4 border-l-slate-300 hover:bg-slate-100/80' : statusConfig.row} ${canExpand ? 'cursor-pointer' : ''} transition-all duration-200 group border-b border-white/50`}
  style={isGap ? { borderLeftStyle: 'dashed' } : undefined}
  onClick={canExpand ? onToggle : undefined}
>
```

Also update `canExpand` (line 873):
```typescript
const canExpand = !isClock && !isGap && !isLunch;
```

**Step 9: Add Lunch stat box in the summary grid (after line 643, before GPS perdu)**

```typescript
{(detail.summary.lunch_minutes ?? 0) > 0 && (
  <div className="group relative overflow-hidden flex flex-col p-4 bg-orange-50/50 rounded-2xl border border-orange-100 shadow-sm transition-all hover:shadow-md">
    <div className="absolute top-0 right-0 p-3 text-orange-200/50 group-hover:scale-110 transition-transform">
      <UtensilsCrossed className="h-12 w-12" />
    </div>
    <span className="text-[10px] uppercase tracking-[0.1em] text-orange-700/60 font-bold mb-1">Diner</span>
    <div className="flex items-baseline gap-1 mt-auto">
      <span className="text-2xl font-black text-orange-700 tracking-tight">{formatHours(detail.summary.lunch_minutes)}</span>
    </div>
  </div>
)}
```

Update the grid columns count to accommodate the new stat:
```typescript
const lunchMinutes = detail.summary.lunch_minutes ?? 0;
const hasLunchStats = lunchMinutes > 0;
const colCount = 4 + (gpsGapTotals.seconds > 0 ? 1 : 0) + (hasLunchStats ? 1 : 0);
```
Use `sm:grid-cols-${colCount}` or a dynamic class.

**Step 10: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: render lunch_start/lunch_end in approval timeline with utensils icon"
```

---

## Task 14: Dashboard — Update `approval-grid.tsx`

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx`

**Step 1: Add lunch info to day cell tooltip**

In the cell rendering where hours are displayed, add lunch info to the tooltip/display. Find where `total_shift_minutes` is shown and add:

```typescript
{day.lunch_minutes > 0 && (
  <span className="text-[10px] text-orange-600">
    {Math.floor(day.lunch_minutes / 60)}h{String(day.lunch_minutes % 60).padStart(2, '0')} diner
  </span>
)}
```

**Step 2: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx
git commit -m "feat: show lunch duration in approval grid cells"
```

---

## Task 15: Edge Case — Server-Side Shift Closure During Lunch

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

**Step 1: Handle server-side closure**

In the shift provider's server closure detection (where it detects the shift was closed by the server), add logic to auto-close any open lunch break:

```dart
// If shift was closed while on lunch, end the lunch break
final lunchState = _ref.read(lunchBreakProvider);
if (lunchState.isOnLunch) {
  final lunchBreak = lunchState.activeLunchBreak!;
  await _localDb.endLunchBreak(lunchBreak.id, DateTime.now().toUtc());
  _ref.read(lunchBreakProvider.notifier).clearOnShiftEnd();
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat: auto-close lunch break on server-side shift closure"
```

---

## Task 16: Verification & Testing

**Step 1: Run Flutter analyze**

```bash
cd gps_tracker && flutter analyze
```
Expected: No new errors.

**Step 2: Run Flutter tests**

```bash
cd gps_tracker && flutter test
```
Expected: All existing tests pass.

**Step 3: Run dashboard build**

```bash
cd dashboard && npm run build
```
Expected: No TypeScript errors.

**Step 4: Manual test checklist**

- [ ] Start shift → lunch button appears (orange pill below clock)
- [ ] Tap "PAUSE DINER" → GPS stops, clock button dims, button turns green "FIN PAUSE"
- [ ] Tap "FIN PAUSE" → GPS resumes, clock button re-enables, button returns to orange
- [ ] Take multiple lunches in one shift → all recorded
- [ ] Kill app during lunch → reopen → "FIN PAUSE" state restored
- [ ] End shift → lunch button disappears
- [ ] Dashboard: open day detail → lunch_start/lunch_end visible in timeline with utensils icon
- [ ] Dashboard: summary shows "Diner" stat box with correct minutes
- [ ] Dashboard: total hours deducts lunch time
- [ ] Dashboard: lunch doesn't create untracked gap

**Step 5: Commit all and push**

```bash
git push origin HEAD
```

---

Plan complete and saved to `docs/plans/2026-03-06-lunch-break-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open a new session with executing-plans, batch execution with checkpoints

Which approach?
