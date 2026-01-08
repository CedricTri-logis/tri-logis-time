# Research: Shift Management

**Feature Branch**: `003-shift-management`
**Date**: 2026-01-08
**Status**: Complete

## Research Summary

This document captures technical research and decisions for the shift management feature implementation.

---

## 1. Offline-First Architecture

### Decision
Use local SQLite (sqflite_sqlcipher) as the single source of truth with background sync to Supabase.

### Rationale
- Guarantees clock-in/out always works regardless of connectivity
- Preserves original device timestamps (FR-010)
- Constitution IV mandates offline-first design
- sqflite_sqlcipher provides encrypted local storage (Constitution IV compliance)

### Alternatives Considered
| Alternative | Why Rejected |
|-------------|--------------|
| Direct Supabase calls only | Fails offline - violates FR-009, Constitution IV |
| PowerSync integration | Over-engineering for simple clock-in/out operations; adds dependency |
| Hive/Isar local DB | Not encrypted by default; sqflite_sqlcipher already in dependencies |

### Implementation Pattern

```dart
// 1. All clock operations write to local DB first
await localDb.insertShift(shift.copyWith(syncStatus: SyncStatus.pending));

// 2. Background sync service processes pending records when online
final pendingShifts = await localDb.getPendingShifts();
for (final shift in pendingShifts) {
  final result = await supabase.rpc('clock_in', params: {...});
  if (result['status'] == 'success') {
    await localDb.markAsSynced(shift.id);
  }
}
```

### Key Details
- **Encryption Key Storage**: Generate key on first launch, store in `flutter_secure_storage`, retrieve before opening database
- **Timestamp Handling**: Store `client_timestamp` (device time) as truth for payroll; server adds `received_at` for audit
- **Conflict Resolution**: Last-Write-Wins based on timestamps; unlikely for single-employee shifts

---

## 2. GPS Location Capture

### Decision
Use geolocator package with tiered accuracy settings and graceful degradation.

### Rationale
- geolocator 12.0.0 already in dependencies
- Supports both iOS and Android with platform-specific optimizations
- Provides accuracy information for low-signal scenarios (FR-012)

### Alternatives Considered
| Alternative | Why Rejected |
|-------------|--------------|
| location package | Less maintained; geolocator already integrated |
| Direct platform channels | Unnecessary complexity; geolocator abstracts well |
| Continuous tracking | Battery drain - Constitution II violation |

### Implementation Pattern

```dart
// Permission check flow
Future<bool> ensureLocationPermission() async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) return false; // Prompt user to enable

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.deniedForever) {
    // Guide to settings
    return false;
  }
  return permission == LocationPermission.whileInUse ||
         permission == LocationPermission.always;
}

// Clock-in location capture (high accuracy, with timeout)
Future<Position?> captureClockLocation() async {
  try {
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 15),
    );
  } on TimeoutException {
    // Fall back to last known or low accuracy
    return Geolocator.getLastKnownPosition();
  }
}
```

### Key Details
- **High accuracy only at clock-in/out**: Reduces battery impact (Constitution II)
- **15-second timeout**: Prevents UI blocking when GPS unavailable indoors
- **Fallback to last known**: Allows clock-in even with weak signal (FR-012)
- **Accuracy stored**: Each clock event includes accuracy in meters for audit

---

## 3. Real-Time Elapsed Timer

### Decision
Use Riverpod StateNotifier with Timer.periodic, persisting shift start timestamp not elapsed ticks.

### Rationale
- Riverpod already in use for state management
- Timer.periodic provides smooth 1Hz updates (SC-003)
- Persisting start timestamp is resilient to app restarts (FR-015)

### Alternatives Considered
| Alternative | Why Rejected |
|-------------|--------------|
| Stream-based timer | More complex; no advantage over periodic |
| Persist elapsed seconds | Loses accuracy if app closed/reopened; timestamp is authoritative |
| Platform-native timer | Adds platform code; violates Constitution I |

### Implementation Pattern

```dart
class ShiftTimerNotifier extends StateNotifier<Duration> {
  Timer? _timer;
  final DateTime startTime;

  ShiftTimerNotifier(this.startTime) : super(Duration.zero) {
    _startTimer();
  }

  void _startTimer() {
    // Calculate initial elapsed (handles app restart)
    state = DateTime.now().difference(startTime);

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = DateTime.now().difference(startTime);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// App lifecycle handling
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    // Recalculate elapsed from persisted start time
    timerNotifier.recalculate();
  }
}
```

### Key Details
- **Recalculate on resume**: Ensures accuracy after background period
- **No persistence of ticks**: Only `clocked_in_at` timestamp stored locally and in Supabase
- **Dispose cleanup**: Timer cancelled via `ref.onDispose` to prevent memory leaks

---

## 4. Sync Status Display

### Decision
Use a dedicated SyncProvider that monitors connectivity and pending queue.

### Rationale
- Users need visibility into sync status (Constitution IV)
- connectivity_plus already in dependencies
- Clear UI feedback on sync state

### Implementation Pattern

```dart
enum SyncStatus { synced, pending, syncing, error }

class SyncNotifier extends StateNotifier<SyncStatus> {
  final Ref _ref;
  StreamSubscription? _connectivitySub;

  SyncNotifier(this._ref) : super(SyncStatus.synced) {
    _listenToConnectivity();
  }

  void _listenToConnectivity() {
    _connectivitySub = Connectivity()
      .onConnectivityChanged
      .listen((result) async {
        if (result != ConnectivityResult.none) {
          await _syncPendingRecords();
        }
      });
  }

  Future<void> _syncPendingRecords() async {
    state = SyncStatus.syncing;
    try {
      // Process pending shifts and GPS points
      await _ref.read(shiftServiceProvider).syncAll();
      state = SyncStatus.synced;
    } catch (e) {
      state = SyncStatus.error;
    }
  }
}
```

---

## 5. Local Database Schema

### Decision
Mirror Supabase schema locally with additional sync tracking columns.

### Rationale
- Consistent data model between local and remote
- Sync status enables reliable queue processing
- sqflite_sqlcipher handles encryption transparently

### Local Tables

```sql
-- Local shifts table (mirrors Supabase with sync tracking)
CREATE TABLE local_shifts (
  id TEXT PRIMARY KEY,          -- UUID from client
  employee_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  clocked_in_at TEXT NOT NULL,  -- ISO8601 timestamp
  clock_in_latitude REAL,
  clock_in_longitude REAL,
  clock_in_accuracy REAL,
  clocked_out_at TEXT,
  clock_out_latitude REAL,
  clock_out_longitude REAL,
  clock_out_accuracy REAL,
  sync_status TEXT NOT NULL DEFAULT 'pending',  -- pending, synced, error
  last_sync_attempt TEXT,
  server_id TEXT,               -- Supabase ID after sync
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Local GPS points (batch synced)
CREATE TABLE local_gps_points (
  id TEXT PRIMARY KEY,          -- Client UUID
  shift_id TEXT NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  accuracy REAL,
  captured_at TEXT NOT NULL,
  sync_status TEXT NOT NULL DEFAULT 'pending',
  FOREIGN KEY (shift_id) REFERENCES local_shifts(id)
);
```

---

## 6. UI/UX Patterns

### Decision
Follow Material Design 3 patterns consistent with existing auth screens.

### Key Patterns
- **Clock Button**: Large, prominent FAB-style button; changes state based on active shift
- **Timer Display**: Large digital clock format (HH:MM:SS) centered on dashboard
- **Status Indicator**: Chip showing sync status (synced/pending/error)
- **History List**: Card-based list with date grouping, infinite scroll pagination
- **Confirmations**: Bottom sheet for clock-out confirmation showing duration

### Visual Feedback (FR-014)
- **Clock-in**: Button animation + success snackbar with start time
- **Clock-out**: Confirmation dialog + summary bottom sheet with duration
- **Sync**: Subtle indicator icon; toast on error

---

## Dependencies Confirmed

All required dependencies already in `pubspec.yaml`:
- `flutter_riverpod: ^2.5.0` - State management
- `supabase_flutter: ^2.12.0` - Backend integration
- `geolocator: ^12.0.0` - GPS location
- `sqflite_sqlcipher: ^3.1.0+1` - Encrypted local storage
- `connectivity_plus: ^6.0.0` - Network monitoring
- `flutter_secure_storage: ^9.2.4` - Encryption key storage
- `uuid: ^4.0.0` - Client ID generation
- `flutter_foreground_task: ^8.0.0` - Background service

No additional dependencies required.

---

## Open Items

None - all technical decisions resolved.
