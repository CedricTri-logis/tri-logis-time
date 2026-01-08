# Local Database Contracts: Shift Management

**Feature Branch**: `003-shift-management`
**Date**: 2026-01-08

## Overview

This document defines the contracts for the local SQLite database operations used for offline-first functionality.

---

## LocalDatabase Service

### Initialization

```dart
abstract class LocalDatabase {
  /// Initialize database with encrypted storage
  /// - Generates encryption key on first run (stored in flutter_secure_storage)
  /// - Creates tables if not exist
  /// - Returns ready database instance
  Future<void> initialize();

  /// Close database connection
  Future<void> close();
}
```

---

## Shift Operations

### Insert Shift (Clock-In)

```dart
/// Insert a new local shift record
/// Called when employee clocks in (before sync attempt)
///
/// @param shift - Shift with syncStatus = pending
/// @throws LocalDatabaseException if insert fails
Future<void> insertShift(LocalShift shift);
```

**Contract**:
- Shift ID must be unique (client-generated UUID)
- Sets `created_at` and `updated_at` to current time
- Sets `sync_status` to 'pending'

### Update Shift (Clock-Out)

```dart
/// Update shift with clock-out data
/// Called when employee clocks out
///
/// @param shiftId - ID of the active shift
/// @param clockedOutAt - Clock-out timestamp
/// @param location - Optional GPS coordinates
/// @param accuracy - Optional GPS accuracy
/// @throws LocalDatabaseException if shift not found
Future<void> updateShiftClockOut({
  required String shiftId,
  required DateTime clockedOutAt,
  GeoPoint? location,
  double? accuracy,
});
```

**Contract**:
- Updates `status` to 'completed'
- Sets `sync_status` to 'pending' (needs sync)
- Updates `updated_at` timestamp

### Get Active Shift

```dart
/// Get the current active shift for an employee
/// Returns null if no active shift exists
///
/// @param employeeId - Employee UUID
Future<LocalShift?> getActiveShift(String employeeId);
```

**SQL**:
```sql
SELECT * FROM local_shifts
WHERE employee_id = ? AND status = 'active'
LIMIT 1
```

### Get Pending Shifts

```dart
/// Get all shifts pending sync
/// Used by SyncService to process queue
///
/// @param employeeId - Employee UUID
Future<List<LocalShift>> getPendingShifts(String employeeId);
```

**SQL**:
```sql
SELECT * FROM local_shifts
WHERE employee_id = ? AND sync_status = 'pending'
ORDER BY created_at ASC
```

### Get Shift History

```dart
/// Get completed shifts for history display
/// Ordered by clock-in time, most recent first
///
/// @param employeeId - Employee UUID
/// @param limit - Max records to return (default 50)
/// @param offset - Pagination offset (default 0)
Future<List<LocalShift>> getShiftHistory({
  required String employeeId,
  int limit = 50,
  int offset = 0,
});
```

**SQL**:
```sql
SELECT * FROM local_shifts
WHERE employee_id = ? AND status = 'completed'
ORDER BY clocked_in_at DESC
LIMIT ? OFFSET ?
```

### Get Shift By ID

```dart
/// Get a specific shift by ID
///
/// @param shiftId - Shift UUID
Future<LocalShift?> getShiftById(String shiftId);
```

### Mark Shift Synced

```dart
/// Mark a shift as successfully synced
/// Called after successful Supabase RPC response
///
/// @param shiftId - Shift UUID
/// @param serverId - Optional server-assigned ID (if different)
Future<void> markShiftSynced(String shiftId, {String? serverId});
```

**Contract**:
- Updates `sync_status` to 'synced'
- Clears `sync_error` if set
- Updates `updated_at`

### Mark Shift Sync Error

```dart
/// Mark a shift sync attempt as failed
/// Called when Supabase RPC returns error
///
/// @param shiftId - Shift UUID
/// @param error - Error message for debugging
Future<void> markShiftSyncError(String shiftId, String error);
```

**Contract**:
- Updates `sync_status` to 'error'
- Sets `sync_error` to error message
- Sets `last_sync_attempt` to current time
- Does NOT prevent retry (error status is retriable)

---

## GPS Point Operations

### Insert GPS Point

```dart
/// Insert a GPS point captured during shift
///
/// @param point - GPS point data
Future<void> insertGpsPoint(LocalGpsPoint point);
```

**Contract**:
- Point ID must be unique (client-generated UUID)
- `captured_at` is the device timestamp when GPS was captured
- `sync_status` defaults to 'pending'

### Get Pending GPS Points

```dart
/// Get all GPS points pending sync
///
/// @param shiftId - Optional: filter by shift
/// @param limit - Max records (default 100 for batch size)
Future<List<LocalGpsPoint>> getPendingGpsPoints({
  String? shiftId,
  int limit = 100,
});
```

**SQL**:
```sql
SELECT * FROM local_gps_points
WHERE sync_status = 'pending'
  AND (? IS NULL OR shift_id = ?)
ORDER BY captured_at ASC
LIMIT ?
```

### Mark GPS Points Synced

```dart
/// Mark multiple GPS points as synced
/// Called after successful batch sync
///
/// @param pointIds - List of point UUIDs
Future<void> markGpsPointsSynced(List<String> pointIds);
```

**SQL**:
```sql
UPDATE local_gps_points
SET sync_status = 'synced'
WHERE id IN (?, ?, ...)
```

### Delete Synced GPS Points

```dart
/// Remove old synced GPS points to free storage
/// Called periodically for cleanup
///
/// @param olderThan - Delete points synced before this time
/// @returns Number of deleted records
Future<int> deleteOldSyncedGpsPoints(DateTime olderThan);
```

**SQL**:
```sql
DELETE FROM local_gps_points
WHERE sync_status = 'synced'
  AND created_at < ?
```

---

## Data Types

### LocalShift

```dart
class LocalShift {
  final String id;
  final String employeeId;
  final String? requestId;
  final String status;           // 'active' | 'completed'
  final DateTime clockedInAt;
  final double? clockInLatitude;
  final double? clockInLongitude;
  final double? clockInAccuracy;
  final DateTime? clockedOutAt;
  final double? clockOutLatitude;
  final double? clockOutLongitude;
  final double? clockOutAccuracy;
  final String syncStatus;       // 'pending' | 'syncing' | 'synced' | 'error'
  final DateTime? lastSyncAttempt;
  final String? syncError;
  final String? serverId;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Conversion to/from Map for SQLite
  Map<String, dynamic> toMap();
  factory LocalShift.fromMap(Map<String, dynamic> map);

  // Conversion to Shift model for UI
  Shift toShift();
}
```

### LocalGpsPoint

```dart
class LocalGpsPoint {
  final String id;
  final String shiftId;
  final String employeeId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;
  final String? deviceId;
  final String syncStatus;       // 'pending' | 'synced'
  final DateTime createdAt;

  Map<String, dynamic> toMap();
  factory LocalGpsPoint.fromMap(Map<String, dynamic> map);
}
```

---

## Error Handling

```dart
class LocalDatabaseException implements Exception {
  final String message;
  final String? operation;
  final dynamic originalError;

  LocalDatabaseException(this.message, {this.operation, this.originalError});
}
```

### Common Errors

| Error | Cause | Handling |
|-------|-------|----------|
| Database not initialized | Called before `initialize()` | Ensure init on app start |
| Encryption key missing | Secure storage corrupted | Re-create key, warn user data may be lost |
| Duplicate ID | Same UUID inserted twice | Log warning, skip insert |
| Foreign key violation | GPS point references missing shift | Ensure shift exists first |

---

## Transaction Support

```dart
/// Execute multiple operations in a transaction
/// Rolls back all changes if any operation fails
Future<T> transaction<T>(Future<T> Function(Transaction txn) action);
```

**Example Usage**:
```dart
await localDb.transaction((txn) async {
  await txn.insertShift(shift);
  await txn.insertGpsPoint(clockInPoint);
});
```

---

## Storage Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max pending shifts | 100 | Unusual to have this many unsynced |
| Max pending GPS points | 10,000 | ~17 hours at 1 point/min |
| Synced data retention | 30 days | Reduce storage; data is in Supabase |

### Cleanup Job

```dart
/// Run periodic cleanup of old synced data
/// Should be called on app launch or background schedule
Future<CleanupStats> performCleanup();
```
