# API Contracts: Project Foundation

**Feature Branch**: `001-project-foundation`
**Date**: 2026-01-08

## Overview

This feature establishes the foundation schema and RPC functions for the GPS Clock-In Tracker. All data access goes through Supabase, using:

1. **Direct table access** via `supabase.from('table')` for reads
2. **RPC functions** via `supabase.rpc('function')` for mutations with business logic

## Database Schema

See: [database-schema.sql](./database-schema.sql)

### Tables

| Table | Description | RLS |
|-------|-------------|-----|
| `employee_profiles` | User profiles linked to auth.users | Yes |
| `shifts` | Work sessions with clock in/out | Yes |
| `gps_points` | Location captures during shifts | Yes |

## RPC Functions

### `clock_in(request_id, location?, accuracy?)`

Start a new work shift.

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `p_request_id` | UUID | Yes | Idempotency key |
| `p_location` | JSONB | No | `{latitude, longitude}` |
| `p_accuracy` | DECIMAL | No | GPS accuracy in meters |

**Returns**: JSONB
```json
// Success
{"status": "success", "shift_id": "uuid", "clocked_in_at": "timestamp"}

// Already processed (idempotent)
{"status": "already_processed", "shift_id": "uuid", "clocked_in_at": "timestamp"}

// Error - already clocked in
{"status": "error", "message": "Already clocked in", "active_shift_id": "uuid"}

// Error - no consent
{"status": "error", "message": "Privacy consent required before clock in"}
```

**Dart Usage**:
```dart
final result = await supabase.rpc('clock_in', params: {
  'p_request_id': Uuid().v4(),
  'p_location': {'latitude': 37.7749, 'longitude': -122.4194},
  'p_accuracy': 10.5,
});
```

---

### `clock_out(shift_id, request_id, location?, accuracy?)`

End an active work shift.

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `p_shift_id` | UUID | Yes | Shift to clock out of |
| `p_request_id` | UUID | Yes | Idempotency key |
| `p_location` | JSONB | No | `{latitude, longitude}` |
| `p_accuracy` | DECIMAL | No | GPS accuracy in meters |

**Returns**: JSONB
```json
// Success
{"status": "success", "shift_id": "uuid", "clocked_out_at": "timestamp"}

// Already processed
{"status": "already_processed", "shift_id": "uuid", "clocked_out_at": "timestamp"}

// Error
{"status": "error", "message": "Shift not found"}
```

**Dart Usage**:
```dart
final result = await supabase.rpc('clock_out', params: {
  'p_shift_id': activeShiftId,
  'p_request_id': Uuid().v4(),
  'p_location': {'latitude': 37.7749, 'longitude': -122.4194},
});
```

---

### `sync_gps_points(points)`

Batch sync GPS points from local storage.

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `p_points` | JSONB[] | Yes | Array of GPS point objects |

**Point Object**:
```json
{
  "client_id": "uuid",
  "shift_id": "uuid",
  "latitude": 37.7749,
  "longitude": -122.4194,
  "accuracy": 10.5,
  "captured_at": "2026-01-08T10:00:00Z",
  "device_id": "optional-device-id"
}
```

**Returns**: JSONB
```json
{"status": "success", "inserted": 10, "duplicates": 2}
```

**Dart Usage**:
```dart
final points = localPoints.map((p) => p.toJson()).toList();
final result = await supabase.rpc('sync_gps_points', params: {
  'p_points': points,
});
```

---

## Direct Table Access Patterns

### Read Employee Profile

```dart
final profile = await supabase
    .from('employee_profiles')
    .select()
    .eq('id', supabase.auth.currentUser!.id)
    .single();
```

### Read Shifts

```dart
// Get all user's shifts
final shifts = await supabase
    .from('shifts')
    .select()
    .order('clocked_in_at', ascending: false);

// Get active shift
final activeShift = await supabase
    .from('shifts')
    .select()
    .eq('status', 'active')
    .maybeSingle();
```

### Read GPS Points for Shift

```dart
final points = await supabase
    .from('gps_points')
    .select()
    .eq('shift_id', shiftId)
    .order('captured_at');
```

### Update Profile (Privacy Consent)

```dart
await supabase
    .from('employee_profiles')
    .update({'privacy_consent_at': DateTime.now().toIso8601String()})
    .eq('id', supabase.auth.currentUser!.id);
```

---

## Error Handling

All RPC functions return a consistent JSONB response with a `status` field:

- `success`: Operation completed
- `already_processed`: Idempotent operation already handled
- `error`: Operation failed, check `message` field

**Dart Error Handling Pattern**:
```dart
try {
  final result = await supabase.rpc('clock_in', params: {...});

  switch (result['status']) {
    case 'success':
      // Handle success
      break;
    case 'already_processed':
      // Return cached result
      break;
    case 'error':
      throw ClockInException(result['message']);
  }
} on PostgrestException catch (e) {
  // Handle Supabase errors
}
```
