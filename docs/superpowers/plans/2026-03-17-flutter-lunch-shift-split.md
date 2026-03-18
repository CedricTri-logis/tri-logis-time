# Flutter Lunch Shift-Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Flutter app to use native shift-split segments for lunch breaks instead of the `lunch_breaks` inbox table.

**Architecture:** New `start_lunch` / `end_lunch` RPCs create shift segments directly. ShiftProvider absorbs lunch logic from the deleted LunchBreakProvider. Local-first optimistic offline with RPC sync on reconnect. Realtime + polling as fallback.

**Tech Stack:** Dart/Flutter, Riverpod, Supabase RPCs, SQLCipher, Supabase Realtime

**Spec:** `docs/superpowers/specs/2026-03-17-flutter-lunch-shift-split-design.md`

---

## Task 1: Create `start_lunch` and `end_lunch` RPCs

**Files:**
- Create: `supabase/migrations/NNN_lunch_shift_split_rpcs.sql`

**Context:** These RPCs split shifts at lunch boundaries. They must be idempotent (safe to retry) and redistribute GPS points by timestamp for the offline case.

- [ ] **Step 1: Write the migration SQL**

Read the existing `shifts` table schema first:
```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'shifts' ORDER BY ordinal_position;
```

Then create the migration file with both RPCs:

```sql
-- start_lunch: closes work segment, creates lunch segment
CREATE OR REPLACE FUNCTION public.start_lunch(
  p_shift_id UUID,
  p_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  v_shift RECORD;
  v_at TIMESTAMPTZ := COALESCE(p_at, NOW());
  v_work_body_id UUID;
  v_new_shift_id UUID;
  v_existing RECORD;
BEGIN
  -- Fetch and lock the shift
  SELECT * INTO v_shift FROM shifts WHERE id = p_shift_id FOR UPDATE;

  IF v_shift IS NULL THEN
    RAISE EXCEPTION 'Shift not found: %', p_shift_id;
  END IF;

  -- Idempotent: if already completed with clock_out_reason='lunch', return existing lunch segment
  IF v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch' THEN
    SELECT id, work_body_id, clocked_in_at INTO v_existing
    FROM shifts
    WHERE work_body_id = v_shift.work_body_id
      AND is_lunch = true
      AND clocked_in_at >= v_shift.clocked_out_at - INTERVAL '1 second'
    ORDER BY clocked_in_at ASC
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object(
        'new_shift_id', v_existing.id,
        'work_body_id', v_existing.work_body_id,
        'started_at', v_existing.clocked_in_at
      );
    END IF;
  END IF;

  IF v_shift.status != 'active' THEN
    RAISE EXCEPTION 'Shift is not active: % (status=%)', p_shift_id, v_shift.status;
  END IF;

  IF v_shift.is_lunch = true THEN
    RAISE EXCEPTION 'Shift is already a lunch segment: %', p_shift_id;
  END IF;

  -- Generate work_body_id if this is the first split
  v_work_body_id := COALESCE(v_shift.work_body_id, gen_random_uuid());

  -- Close the work segment
  UPDATE shifts SET
    status = 'completed',
    clocked_out_at = v_at,
    clock_out_reason = 'lunch',
    work_body_id = v_work_body_id
  WHERE id = p_shift_id;

  -- Create the lunch segment
  v_new_shift_id := gen_random_uuid();
  INSERT INTO shifts (
    id, employee_id, clocked_in_at, status, shift_type,
    work_body_id, is_lunch,
    clock_in_location_id, clock_in_cluster_id
  )
  SELECT
    v_new_shift_id, v_shift.employee_id, v_at, 'active', v_shift.shift_type,
    v_work_body_id, true,
    v_shift.clock_in_location_id, v_shift.clock_in_cluster_id
  ;

  -- Redistribute GPS points captured after p_at to the new lunch segment
  UPDATE gps_points SET shift_id = v_new_shift_id
  WHERE shift_id = p_shift_id AND captured_at > v_at;

  RETURN jsonb_build_object(
    'new_shift_id', v_new_shift_id,
    'work_body_id', v_work_body_id,
    'started_at', v_at
  );
END;
$$;

-- end_lunch: closes lunch segment, creates new work segment
CREATE OR REPLACE FUNCTION public.end_lunch(
  p_shift_id UUID,
  p_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  v_shift RECORD;
  v_at TIMESTAMPTZ := COALESCE(p_at, NOW());
  v_new_shift_id UUID;
  v_existing RECORD;
BEGIN
  -- Fetch and lock the shift
  SELECT * INTO v_shift FROM shifts WHERE id = p_shift_id FOR UPDATE;

  IF v_shift IS NULL THEN
    RAISE EXCEPTION 'Shift not found: %', p_shift_id;
  END IF;

  -- Idempotent: if already completed with clock_out_reason='lunch_end', return existing work segment
  IF v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch_end' THEN
    SELECT id, work_body_id, clocked_in_at INTO v_existing
    FROM shifts
    WHERE work_body_id = v_shift.work_body_id
      AND is_lunch = false
      AND clocked_in_at >= v_shift.clocked_out_at - INTERVAL '1 second'
    ORDER BY clocked_in_at ASC
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object(
        'new_shift_id', v_existing.id,
        'work_body_id', v_existing.work_body_id,
        'started_at', v_existing.clocked_in_at
      );
    END IF;
  END IF;

  IF v_shift.status != 'active' THEN
    RAISE EXCEPTION 'Shift is not active: % (status=%)', p_shift_id, v_shift.status;
  END IF;

  IF v_shift.is_lunch != true THEN
    RAISE EXCEPTION 'Shift is not a lunch segment: %', p_shift_id;
  END IF;

  -- Close the lunch segment
  UPDATE shifts SET
    status = 'completed',
    clocked_out_at = v_at,
    clock_out_reason = 'lunch_end'
  WHERE id = p_shift_id;

  -- Create the new work segment
  v_new_shift_id := gen_random_uuid();
  INSERT INTO shifts (
    id, employee_id, clocked_in_at, status, shift_type,
    work_body_id, is_lunch,
    clock_in_location_id, clock_in_cluster_id
  )
  SELECT
    v_new_shift_id, v_shift.employee_id, v_at, 'active', v_shift.shift_type,
    v_shift.work_body_id, false,
    v_shift.clock_in_location_id, v_shift.clock_in_cluster_id
  ;

  -- Redistribute GPS points captured after p_at to the new work segment
  -- This handles the offline case: GPS resumed with old shift_id before sync
  UPDATE gps_points SET shift_id = v_new_shift_id
  WHERE shift_id = p_shift_id AND captured_at > v_at;

  RETURN jsonb_build_object(
    'new_shift_id', v_new_shift_id,
    'work_body_id', v_shift.work_body_id,
    'started_at', v_at
  );
END;
$$;
```

- [ ] **Step 2: Apply the migration**

Use `mcp__supabase__apply_migration` or:
```bash
supabase db push
```

- [ ] **Step 3: Test the RPCs manually**

Run via `mcp__supabase__execute_sql`:
```sql
-- Verify functions exist
SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name IN ('start_lunch', 'end_lunch');
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/NNN_lunch_shift_split_rpcs.sql
git commit -m "feat(db): add start_lunch and end_lunch RPCs for native shift-split"
```

---

## Task 2: Update data models (`Shift`, `LocalShift`, `SyncStatus`)

**Files:**
- Modify: `gps_tracker/lib/features/shifts/models/shift.dart:9-135`
- Modify: `gps_tracker/lib/features/shifts/models/local_shift.dart:6-183`
- Modify: `gps_tracker/lib/features/shifts/models/shift_enums.dart:15-27`

**Context:** Add `workBodyId`, `isLunch`, `clockOutReason` to both models. Add `lunchStartedAt`/`lunchEndedAt` offline tracking to LocalShift. Add `lunchPending`/`lunchEndPending` to SyncStatus enum.

- [ ] **Step 1: Update `SyncStatus` enum**

In `gps_tracker/lib/features/shifts/models/shift_enums.dart`, add two values to the `SyncStatus` enum:

```dart
enum SyncStatus {
  pending,
  syncing,
  synced,
  error,
  lunchPending,      // NEW: lunch start awaiting RPC call
  lunchEndPending,   // NEW: lunch end awaiting RPC call
}
```

- [ ] **Step 2: Update `Shift` model**

In `gps_tracker/lib/features/shifts/models/shift.dart`:

Add fields to the class:
```dart
final String? workBodyId;
final bool isLunch;
final String? clockOutReason;
```

Add computed property:
```dart
bool get isOnLunch => isLunch && status == ShiftStatus.active;
```

Update `fromJson()` to parse:
```dart
workBodyId: json['work_body_id'] as String?,
isLunch: json['is_lunch'] as bool? ?? false,
clockOutReason: json['clock_out_reason'] as String?,
```

Update `toJson()`, `copyWith()`, and constructor to include the new fields.

- [ ] **Step 3: Update `LocalShift` model**

In `gps_tracker/lib/features/shifts/models/local_shift.dart`:

Add fields:
```dart
final String? workBodyId;
final bool isLunch;
final String? clockOutReason;
final DateTime? lunchStartedAt;
final DateTime? lunchEndedAt;
```

Add computed properties:
```dart
bool get isOnLunch => isLunch && status == 'active';
bool get isPartOfLunchGroup => workBodyId != null;
```

Update `fromMap()`:
```dart
workBodyId: map['work_body_id'] as String?,
isLunch: (map['is_lunch'] as int? ?? 0) == 1,
clockOutReason: map['clock_out_reason'] as String?,
lunchStartedAt: map['lunch_started_at'] != null
    ? DateTime.parse(map['lunch_started_at'] as String)
    : null,
lunchEndedAt: map['lunch_ended_at'] != null
    ? DateTime.parse(map['lunch_ended_at'] as String)
    : null,
```

Update `toMap()`:
```dart
'work_body_id': workBodyId,
'is_lunch': isLunch ? 1 : 0,
'clock_out_reason': clockOutReason,
'lunch_started_at': lunchStartedAt?.toIso8601String(),
'lunch_ended_at': lunchEndedAt?.toIso8601String(),
```

Update `toShift()` to pass `workBodyId`, `isLunch`, `clockOutReason` to the `Shift` constructor.

Update `copyWith()` to include all new fields.

- [ ] **Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

Fix any issues. There will be compilation errors in files that construct `Shift` or `LocalShift` without the new fields — that's expected and will be fixed in later tasks.

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/shifts/models/
git commit -m "feat(models): add lunch shift-split fields to Shift, LocalShift, SyncStatus"
```

---

## Task 3: SQLCipher migration (v10 → v11)

**Files:**
- Modify: `gps_tracker/lib/shared/services/local_database.dart:27` (version bump)
- Modify: `gps_tracker/lib/shared/services/local_database.dart` (onUpgrade handler)

**Context:** Add the 5 new columns to `local_shifts`. The `local_lunch_breaks` table stays (Option C later).

- [ ] **Step 1: Read current database version and onUpgrade handler**

Read `gps_tracker/lib/shared/services/local_database.dart` to find the current `_databaseVersion` and the existing `onUpgrade` handler pattern.

- [ ] **Step 2: Bump version and add migration**

Update `_databaseVersion` from 10 to 11.

Add to the `onUpgrade` handler, in the version switch/if chain:

```dart
if (oldVersion < 11) {
  await db.execute('ALTER TABLE local_shifts ADD COLUMN work_body_id TEXT');
  await db.execute('ALTER TABLE local_shifts ADD COLUMN is_lunch INTEGER DEFAULT 0');
  await db.execute('ALTER TABLE local_shifts ADD COLUMN clock_out_reason TEXT');
  await db.execute('ALTER TABLE local_shifts ADD COLUMN lunch_started_at TEXT');
  await db.execute('ALTER TABLE local_shifts ADD COLUMN lunch_ended_at TEXT');
}
```

Also update the `onCreate` table definition for `local_shifts` to include the new columns (for fresh installs).

**Important — CHECK constraint**: The existing `local_shifts` table has a CHECK constraint on `sync_status` that only allows `('pending', 'syncing', 'synced', 'error')`. SQLite `ALTER TABLE` cannot modify CHECK constraints. Two approaches:
- Remove the CHECK constraint from the `_onCreate` definition (for fresh installs) and accept that the v10→v11 migration won't enforce it on existing tables (SQLite CHECK constraints are not enforced on ALTER TABLE anyway, only on CREATE TABLE).
- Or recreate the table with the expanded CHECK — but this is complex and unnecessary since `sync_status` is validated at the Dart enum level.

Recommended: remove the CHECK constraint from `_onCreate` for `sync_status` entirely — the Dart `SyncStatus` enum is the source of truth.

- [ ] **Step 3: Add lunch-related DB helper methods**

Add to `LocalDatabase`:

```dart
/// Mark a local shift as lunch-pending (offline start lunch)
Future<void> markLunchPending(String shiftId, DateTime lunchStartedAt) async {
  final db = await database;
  await db.update(
    'local_shifts',
    {
      'lunch_started_at': lunchStartedAt.toIso8601String(),
      'sync_status': SyncStatus.lunchPending.name,
    },
    where: 'id = ?',
    whereArgs: [shiftId],
  );
}

/// Mark a local shift as lunch-end-pending (offline end lunch)
Future<void> markLunchEndPending(String shiftId, DateTime lunchEndedAt) async {
  final db = await database;
  await db.update(
    'local_shifts',
    {
      'lunch_ended_at': lunchEndedAt.toIso8601String(),
      'sync_status': SyncStatus.lunchEndPending.name,
    },
    where: 'id = ?',
    whereArgs: [shiftId],
  );
}

/// Get all shifts with pending lunch operations, ordered chronologically
Future<List<LocalShift>> getLunchPendingShifts() async {
  final db = await database;
  final results = await db.query(
    'local_shifts',
    where: 'sync_status IN (?, ?)',
    whereArgs: [SyncStatus.lunchPending.name, SyncStatus.lunchEndPending.name],
    orderBy: 'lunch_started_at ASC, lunch_ended_at ASC',
  );
  return results.map((map) => LocalShift.fromMap(map)).toList();
}

/// Create a new local shift segment (used when RPC returns new_shift_id)
Future<void> insertShiftSegment(LocalShift segment) async {
  final db = await database;
  await db.insert('local_shifts', segment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);
}
```

- [ ] **Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/shared/services/local_database.dart
git commit -m "feat(db): SQLCipher v11 migration — add lunch shift-split columns"
```

---

## Task 4: Add `pauseForLunch()` to `TrackingProvider`

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

**Context:** The `pauseForLunch()` method does not currently exist on `TrackingNotifier`. It must pause GPS collection while keeping resilience mechanisms (SLC, BAS, BGAppRefresh) alive so the app can recover if killed during lunch.

- [ ] **Step 1: Read TrackingProvider**

Read `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — focus on `startTracking()` and `stopTracking()` to understand the current patterns and what resilience mechanisms exist.

- [ ] **Step 2: Implement `pauseForLunch()`**

Add to `TrackingNotifier`:

```dart
/// Pause GPS collection for lunch break.
/// Stops the periodic GPS stream but keeps resilience mechanisms alive
/// (SLC on iOS, BAS on Android, BGAppRefresh) so the app can recover
/// if killed by the OS during the break.
Future<void> pauseForLunch() async {
  debugPrint('[TrackingProvider] pauseForLunch — stopping GPS stream only');
  // Stop the GPS position stream
  _positionStreamSubscription?.cancel();
  _positionStreamSubscription = null;
  // Do NOT call stopTracking() — that would also stop the foreground service
  // and disable resilience mechanisms. We only want to pause GPS collection.
  state = state.copyWith(isTracking: false);
}
```

Note: read the actual file first to understand the exact state shape and stream variable names. The above is a pattern — adapt field names to match the actual code.

- [ ] **Step 3: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git commit -m "feat(tracking): add pauseForLunch to pause GPS without stopping resilience mechanisms"
```

---

## Task 5: Add `startLunch` / `endLunch` to `ShiftService`

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/shift_service.dart`

**Context:** Add service methods that call the `start_lunch` / `end_lunch` RPCs and return the result. Pattern should match existing `clockIn()` / `clockOut()`.

- [ ] **Step 1: Read ShiftService to understand the clockIn/clockOut pattern**

Read `gps_tracker/lib/features/shifts/services/shift_service.dart` — focus on `clockIn()` and `clockOut()` methods for the RPC call pattern.

- [ ] **Step 2: Create a `LunchResult` class**

Add near the top of the file (following ClockInResult/ClockOutResult pattern):

```dart
class LunchResult {
  final String newShiftId;
  final String workBodyId;
  final DateTime startedAt;

  LunchResult({
    required this.newShiftId,
    required this.workBodyId,
    required this.startedAt,
  });

  factory LunchResult.fromJson(Map<String, dynamic> json) {
    return LunchResult(
      newShiftId: json['new_shift_id'] as String,
      workBodyId: json['work_body_id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
    );
  }
}
```

- [ ] **Step 3: Add `startLunch()` method**

```dart
Future<LunchResult> startLunch(String shiftId, {DateTime? at}) async {
  final response = await _supabase.rpc('start_lunch', params: {
    'p_shift_id': shiftId,
    if (at != null) 'p_at': at.toUtc().toIso8601String(),
  });

  return LunchResult.fromJson(response as Map<String, dynamic>);
}
```

- [ ] **Step 4: Add `endLunch()` method**

```dart
Future<LunchResult> endLunch(String shiftId, {DateTime? at}) async {
  final response = await _supabase.rpc('end_lunch', params: {
    'p_shift_id': shiftId,
    if (at != null) 'p_at': at.toUtc().toIso8601String(),
  });

  return LunchResult.fromJson(response as Map<String, dynamic>);
}
```

- [ ] **Step 5: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/shift_service.dart
git commit -m "feat(service): add startLunch/endLunch RPC methods to ShiftService"
```

---

## Task 6: Update `ShiftProvider` — state, `startLunch()`, `endLunch()`

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart:38-74` (ShiftState)
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart` (ShiftNotifier — add methods)

**Context:** This is the core task. ShiftState gains `isStartingLunch`/`isEndingLunch`. ShiftNotifier gains `startLunch()` and `endLunch()` methods with online/offline branching.

- [ ] **Step 1: Read ShiftProvider thoroughly**

Read `gps_tracker/lib/features/shifts/providers/shift_provider.dart` in full to understand the current state shape, the clockIn/clockOut patterns, and the init flow.

- [ ] **Step 2: Update `ShiftState`**

Add to `ShiftState` class:

```dart
final bool isStartingLunch;
final bool isEndingLunch;
```

Initialize both to `false` in the constructor. Add to `copyWith()`.

- [ ] **Step 3: Implement `startLunch()`**

Add to `ShiftNotifier`. Follow the pattern of `clockOut()` but with lunch-specific logic:

Note: `ShiftNotifier` does not have a `_localDb` field — access LocalDatabase via `_ref.read(localDatabaseProvider)`. All code below uses `localDb` shorthand for this.

```dart
Future<void> startLunch() async {
  final shift = state.activeShift;
  if (shift == null || shift.isOnLunch) return;
  if (state.isStartingLunch) return; // double-tap guard

  state = state.copyWith(isStartingLunch: true, error: null);
  final now = DateTime.now();
  final localDb = _ref.read(localDatabaseProvider);

  try {
    // 1. Record lunch_started_at locally
    await localDb.markLunchPending(shift.id, now);

    // 2. Close active work session
    _ref.read(workSessionProvider.notifier).manualClose();

    // 3. Pause GPS (keep resilience mechanisms alive)
    await _ref.read(trackingProvider.notifier).pauseForLunch();

    // 4. Update Live Activity
    ShiftActivityService.instance.updateStatus('lunch');

    // 5. Try RPC (online path)
    try {
      final result = await _shiftService.startLunch(shift.id, at: now);

      // Create local lunch segment
      // NOTE: Adapt constructor params to match actual LocalShift fields.
      // Read local_shift.dart first — key fields are clockedInAt (not startedAt),
      // syncStatus is a String (not SyncStatus enum), and createdAt/updatedAt are required.
      final lunchSegment = LocalShift(
        id: result.newShiftId,
        employeeId: shift.employeeId,
        clockedInAt: result.startedAt,
        status: 'active',
        syncStatus: 'synced',
        workBodyId: result.workBodyId,
        isLunch: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await localDb.insertShiftSegment(lunchSegment);

      // Update active shift
      state = state.copyWith(
        activeShift: lunchSegment.toShift(),
        isStartingLunch: false,
      );
    } catch (e) {
      // 6. Offline fallback — UI already shows lunch state
      debugPrint('startLunch RPC failed, falling back to offline: $e');

      // Create a local-only lunch representation using the existing shift
      final offlineLunchShift = shift.copyWith(
        isLunch: true,
        workBodyId: shift.workBodyId ?? const Uuid().v4(),
      );
      state = state.copyWith(
        activeShift: offlineLunchShift,
        isStartingLunch: false,
      );
    }

    // Notify sync
    _ref.read(syncProvider.notifier).notifyPendingData();
  } catch (e) {
    state = state.copyWith(isStartingLunch: false, error: e.toString());
  }
}
```

- [ ] **Step 4: Implement `endLunch()`**

```dart
Future<void> endLunch() async {
  final shift = state.activeShift;
  if (shift == null || !shift.isOnLunch) return;
  if (state.isEndingLunch) return; // double-tap guard

  state = state.copyWith(isEndingLunch: true, error: null);
  final now = DateTime.now();
  final localDb = _ref.read(localDatabaseProvider);

  try {
    // 1. Record lunch_ended_at locally
    await localDb.markLunchEndPending(shift.id, now);

    String activeShiftId = shift.id;

    // 2. Try RPC (online path)
    try {
      final result = await _shiftService.endLunch(shift.id, at: now);

      // Create local work segment
      final workSegment = LocalShift(
        id: result.newShiftId,
        employeeId: shift.employeeId,
        clockedInAt: result.startedAt,
        status: 'active',
        syncStatus: 'synced',
        workBodyId: result.workBodyId,
        isLunch: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await localDb.insertShiftSegment(workSegment);

      activeShiftId = result.newShiftId;

      state = state.copyWith(
        activeShift: workSegment.toShift(),
        isEndingLunch: false,
      );
    } catch (e) {
      // 3. Offline fallback — resume GPS with same shift_id
      debugPrint('endLunch RPC failed, falling back to offline: $e');

      final offlineWorkShift = shift.copyWith(isLunch: false);
      state = state.copyWith(
        activeShift: offlineWorkShift,
        isEndingLunch: false,
      );
    }

    // 4. Resume GPS (after shift_id is resolved)
    await ensureGpsAlive(_ref, source: 'lunch_end');
    await _ref.read(trackingProvider.notifier).startTracking();

    // 5. Update Live Activity
    ShiftActivityService.instance.updateStatus('active');

    // Notify sync
    _ref.read(syncProvider.notifier).notifyPendingData();
  } catch (e) {
    state = state.copyWith(isEndingLunch: false, error: e.toString());
  }
}
```

- [ ] **Step 5: Update `_loadActiveShift()` to restore lunch state**

In the `_loadActiveShift()` method (the init method in ShiftNotifier), after loading the active shift from local DB, check if it has `lunchPending` sync_status:

```dart
// Restore lunch state if app was killed during offline lunch
if (localShift != null &&
    localShift.syncStatus == SyncStatus.lunchPending.name &&
    localShift.lunchStartedAt != null) {
  // The shift is in lunch state locally
  final lunchShift = localShift.toShift().copyWith(isLunch: true);
  state = state.copyWith(activeShift: lunchShift);
  // Keep GPS paused
  await _ref.read(trackingProvider.notifier).pauseForLunch();
  ShiftActivityService.instance.updateStatus('lunch');
}
```

- [ ] **Step 6: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat(provider): add startLunch/endLunch to ShiftProvider with offline support"
```

---

## Task 7: Lunch-aware Realtime and polling handlers

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart:102-107` (Realtime setup)
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart:109-126` (`_handleServerShiftUpdate`)
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart:169-296` (`_checkServerShiftStatus`)
- Possibly modify: `gps_tracker/lib/shared/services/realtime_service.dart` (if Realtime channel setup is there)

**Context:** Prevent `_closeShiftLocally()` from firing on lunch transitions. Subscribe to INSERT events. Fetch sibling segment by `work_body_id` on lunch transitions.

- [ ] **Step 1: Read the Realtime setup and handlers**

Read `shift_provider.dart` lines 102-327 to understand the current Realtime channel setup, `_handleServerShiftUpdate`, `_checkServerShiftStatus`, and `_closeShiftLocally`.

- [ ] **Step 2: Update Realtime subscription to include INSERT events**

In `_setupRealtimeListener()`, add a second listener for INSERT events alongside the existing UPDATE listener. Both should call `_handleServerShiftChange` (a renamed/unified handler).

- [ ] **Step 3: Create `_handleLunchTransition()` helper**

```dart
Future<void> _handleLunchTransition(String workBodyId) async {
  // Fetch the active sibling segment
  final response = await _supabase
      .from('shifts')
      .select()
      .eq('work_body_id', workBodyId)
      .eq('status', 'active')
      .maybeSingle();

  if (response != null) {
    final newShift = Shift.fromJson(response);
    state = state.copyWith(activeShift: newShift);

    // Update Live Activity based on new segment type
    if (newShift.isLunch) {
      ShiftActivityService.instance.updateStatus('lunch');
    } else {
      ShiftActivityService.instance.updateStatus('active');
    }
  }
}
```

- [ ] **Step 4: Update `_handleServerShiftUpdate` for lunch awareness**

When a completed status is received:
```dart
if (clockOutReason == 'lunch' || clockOutReason == 'lunch_end') {
  // Lunch transition — do NOT call _closeShiftLocally
  final workBodyId = payload['work_body_id'] as String?;
  if (workBodyId != null) {
    await _handleLunchTransition(workBodyId);
  }
  return;
}
// ... existing close behavior for other reasons
```

For INSERT events: if the new record has the same `work_body_id` as current active shift and `status='active'`, transition to it (confirmation/recovery path).

- [ ] **Step 5: Update `_checkServerShiftStatus` for lunch awareness**

Update the server query to also fetch `work_body_id`:
```dart
final response = await _supabase
    .from('shifts')
    .select('id, status, clock_out_reason, work_body_id')
    .eq('id', shift.id)
    .maybeSingle();
```

Add lunch check before `_closeShiftLocally`:
```dart
if (serverStatus == 'completed') {
  final clockOutReason = response['clock_out_reason'] as String?;
  if (clockOutReason == 'lunch' || clockOutReason == 'lunch_end') {
    final workBodyId = response['work_body_id'] as String?;
    if (workBodyId != null) {
      await _handleLunchTransition(workBodyId);
    }
    return;
  }
  // ... existing close behavior
}
```

- [ ] **Step 6: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat(provider): lunch-aware Realtime and polling handlers"
```

---

## Task 8: Update `SyncService` for lunch RPC sync

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart:86-184` (`syncAll`)

**Context:** Before normal shift/GPS sync, process any lunch-pending shifts by calling the RPCs with saved timestamps.

- [ ] **Step 1: Read SyncService.syncAll()**

Read `gps_tracker/lib/features/shifts/services/sync_service.dart` to understand the sync flow.

- [ ] **Step 2: Add lunch sync step at the beginning of `syncAll()`**

At the top of `syncAll()`, before the existing shift sync:

```dart
// Step 0: Process pending lunch operations via RPCs
final lunchPendingShifts = await _localDb.getLunchPendingShifts();
for (final shift in lunchPendingShifts) {
  try {
    if (shift.syncStatus == SyncStatus.lunchPending && shift.lunchStartedAt != null) {
      final result = await _shiftService.startLunch(
        shift.serverId ?? shift.id,
        at: shift.lunchStartedAt!,
      );
      // Create local lunch segment with server ID
      final lunchSegment = LocalShift(
        id: result.newShiftId,
        employeeId: shift.employeeId,
        clockedInAt: result.startedAt,
        status: 'active',
        syncStatus: 'synced',
        workBodyId: result.workBodyId,
        isLunch: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await _localDb.insertShiftSegment(lunchSegment);
      await _localDb.markShiftSynced(shift.id);

    } else if (shift.syncStatus == SyncStatus.lunchEndPending && shift.lunchEndedAt != null) {
      final result = await _shiftService.endLunch(
        shift.serverId ?? shift.id,
        at: shift.lunchEndedAt!,
      );
      // Create local work segment with server ID
      final workSegment = LocalShift(
        id: result.newShiftId,
        employeeId: shift.employeeId,
        clockedInAt: result.startedAt,
        status: 'active',
        syncStatus: 'synced',
        workBodyId: result.workBodyId,
        isLunch: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await _localDb.insertShiftSegment(workSegment);
      await _localDb.markShiftSynced(shift.id);
    }
  } catch (e) {
    debugPrint('Lunch sync failed for shift ${shift.id}: $e');
    // Leave as pending — will retry on next sync cycle
  }
}
```

- [ ] **Step 3: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/sync_service.dart
git commit -m "feat(sync): add lunch RPC sync path before normal shift/GPS sync"
```

---

## Task 9: Rewrite `LunchBreakButton` and update dashboard

**Files:**
- Modify: `gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Context:** The button keeps its visual design but reads from `shiftProvider` instead of `lunchBreakProvider`. The dashboard may need minor updates for import changes.

- [ ] **Step 1: Read current LunchBreakButton and ShiftDashboardScreen**

Read both files to understand the current widget structure and how the button is integrated.

- [ ] **Step 2: Rewrite `LunchBreakButton`**

Replace the provider reads:
```dart
// OLD
final lunchState = ref.watch(lunchBreakProvider);
final isOnLunch = lunchState.isOnLunch;
final isLoading = lunchState.isStarting || lunchState.isEnding;

// NEW
final shiftState = ref.watch(shiftProvider);
final isOnLunch = shiftState.activeShift?.isOnLunch ?? false;
final isLoading = shiftState.isStartingLunch || shiftState.isEndingLunch;
```

Replace the callbacks:
```dart
// OLD
ref.read(lunchBreakProvider.notifier).startLunchBreak();
ref.read(lunchBreakProvider.notifier).endLunchBreak();

// NEW
ref.read(shiftProvider.notifier).startLunch();
ref.read(shiftProvider.notifier).endLunch();
```

Keep all visual elements (colors, icons, labels, layout) unchanged.

- [ ] **Step 3: Update ShiftDashboardScreen**

Remove any imports/references to `lunchBreakProvider`. The lunch button should work with just `shiftProvider` now.

Also ensure the clock-out button is disabled when `isOnLunch`:
```dart
// Disable clock-out during lunch
onPressed: (shiftState.activeShift?.isOnLunch ?? false) ? null : () => clockOut(),
```

- [ ] **Step 4: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat(ui): rewrite LunchBreakButton to use ShiftProvider"
```

---

## Task 10: Delete `LunchBreakProvider` and related code

**Files:**
- Delete: `gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart`
- Delete: `gps_tracker/lib/features/shifts/models/lunch_break.dart`
- Modify: any files that import the deleted files

**Context:** Remove the old lunch infrastructure. The old `local_lunch_breaks` table and Supabase `lunch_breaks` table stay (Option C later).

- [ ] **Step 1: Find all imports of deleted files**

Search for:
```
import.*lunch_break_provider
import.*lunch_break\.dart
import.*models/lunch_break
```

- [ ] **Step 2: Remove imports and references from all files**

For each file that imports the deleted modules, remove the import and any usage. Key files to check:
- `shift_provider.dart` — remove `lunchBreakProvider.notifier.clearOnShiftEnd()` from `_closeShiftLocally()` (or replace with shift-based cleanup)
- `sync_provider.dart` — remove lunch_breaks sync code
- `shift_dashboard_screen.dart` — already updated in Task 8
- Any other files found in Step 1

- [ ] **Step 3: Remove lunch_breaks sync from SyncService**

In `sync_service.dart` (NOT sync_provider.dart), find and remove the `_syncLunchBreaks()` method and its call from `syncAll()`. This is no longer needed since lunch operations go through RPCs.

- [ ] **Step 4: Delete the files**

```bash
rm gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart
rm gps_tracker/lib/features/shifts/models/lunch_break.dart
```

- [ ] **Step 5: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

Fix ALL remaining compilation errors. Every reference to the deleted files must be resolved.

- [ ] **Step 6: Commit**

```bash
git add -A gps_tracker/lib/
git commit -m "refactor: delete LunchBreakProvider and LunchBreak model — lunch is now a shift segment"
```

---

## Task 11: Work session history with lunch segments

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/widgets/work_session_history_list.dart` (uses `LunchBreak`, `lunchBreaksForShiftProvider`, `_LunchBreakTile`)
- Modify: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart` (imports `lunch_break_provider`, uses `lunchState.isOnLunch`, `_buildLunchCard`)
- Modify: `gps_tracker/lib/features/shifts/screens/shift_history_screen.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_card.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_summary_card.dart`
- Possibly modify: `gps_tracker/lib/features/shifts/widgets/shift_timer.dart` (references `isOnLunch`)

**Context:** The employee must see lunch breaks in their shift history. Segments are grouped by `work_body_id`. This is the key UX requirement. Several widgets reference the old `LunchBreak` model and `lunchBreakProvider` and must be rewritten.

- [ ] **Step 1: Find all lunch references in history/work session widgets**

Search for all files referencing old lunch types:
```
grep -r "LunchBreak\|lunchBreak\|lunch_break" gps_tracker/lib/features/work_sessions/
grep -r "LunchBreak\|lunchBreak\|lunch_break" gps_tracker/lib/features/shifts/widgets/
grep -r "LunchBreak\|lunchBreak\|lunch_break" gps_tracker/lib/features/shifts/screens/
grep -r "LunchBreak\|lunchBreak\|lunch_break" gps_tracker/lib/features/history/
```

- [ ] **Step 2: Rewrite `work_session_history_list.dart`**

Replace all `LunchBreak` model usage and `lunchBreaksForShiftProvider` with shift-segment based queries:
- Remove import of `lunch_break.dart` and `lunch_break_provider.dart`
- Replace `_LunchBreakTile` with a tile that reads from `LocalShift` segments where `isLunch=true`
- Query: `SELECT * FROM local_shifts WHERE work_body_id = ? ORDER BY clocked_in_at ASC`
- Note: use `WHERE work_body_id IS NOT NULL AND work_body_id = ?` (SQL `= NULL` returns no rows)

- [ ] **Step 3: Rewrite `active_work_session_card.dart`**

Replace `lunchBreakProvider` references:
- Remove import of `lunch_break_provider.dart`
- Replace `lunchState.isOnLunch` with `shiftState.activeShift?.isOnLunch ?? false`
- Replace `_buildLunchCard` with shift-segment based display

- [ ] **Step 4: Update shift card/timeline widget**

Display lunch segments as distinct rows in the shift timeline:
- Work segments: regular display with duration
- Lunch segments (`isLunch=true`): show as "Pause dîner HH:MM → HH:MM (duration)"
- Footer: "Total travail: Xh / Total pauses: Xh"

- [ ] **Step 5: Replace `totalLunchDurationProvider`**

Find all references to `totalLunchDurationProvider` and replace with a derivation:

```dart
// Sum lunch durations from segments with same work_body_id
final lunchDuration = segments
    .where((s) => s.isLunch && s.clockedOutAt != null)
    .fold<Duration>(Duration.zero, (sum, s) => sum + s.clockedOutAt!.difference(s.clockedInAt));
```

- [ ] **Step 5: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/features/
git commit -m "feat(history): display lunch segments in shift history timeline"
```

---

## Task 12: Final integration and cleanup

**Files:**
- All modified files from previous tasks

**Context:** Ensure everything compiles, all references are resolved, and the app runs.

- [ ] **Step 1: Full `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

Fix any remaining issues.

- [ ] **Step 2: Search for orphaned references**

Search the entire codebase for any remaining references to the old lunch system:

```
grep -r "lunchBreak" gps_tracker/lib/
grep -r "lunch_break" gps_tracker/lib/
grep -r "LunchBreak" gps_tracker/lib/
grep -r "isOnLunchProvider" gps_tracker/lib/
grep -r "lunchBreaksForShiftProvider" gps_tracker/lib/
grep -r "totalLunchDurationProvider" gps_tracker/lib/
```

The only remaining references should be to `local_lunch_breaks` table in `local_database.dart` (kept for Option C).

- [ ] **Step 3: Verify the app builds**

```bash
cd gps_tracker && flutter build apk --debug
```

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A gps_tracker/
git commit -m "chore: final cleanup for lunch shift-split refactor"
```
