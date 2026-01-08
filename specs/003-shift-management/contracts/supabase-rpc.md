# Supabase RPC Contracts: Shift Management

**Feature Branch**: `003-shift-management`
**Date**: 2026-01-08

## Overview

This document defines the contracts for Supabase RPC (Remote Procedure Call) functions used by the shift management feature. These functions already exist in `supabase/migrations/001_initial_schema.sql`.

---

## 1. clock_in

Idempotent clock-in operation with validation.

### Signature

```sql
clock_in(
  p_request_id UUID,
  p_location JSONB DEFAULT NULL,
  p_accuracy DECIMAL DEFAULT NULL
) RETURNS JSONB
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_request_id | UUID | Yes | Client-generated idempotency key |
| p_location | JSONB | No | `{latitude: number, longitude: number}` |
| p_accuracy | DECIMAL | No | GPS accuracy in meters |

### Response

#### Success

```json
{
  "status": "success",
  "shift_id": "uuid",
  "clocked_in_at": "2026-01-08T09:00:00.000Z"
}
```

#### Already Processed (Idempotent)

```json
{
  "status": "already_processed",
  "shift_id": "uuid",
  "clocked_in_at": "2026-01-08T09:00:00.000Z"
}
```

#### Error - Already Clocked In

```json
{
  "status": "error",
  "message": "Already clocked in",
  "active_shift_id": "uuid"
}
```

#### Error - No Privacy Consent

```json
{
  "status": "error",
  "message": "Privacy consent required before clock in"
}
```

#### Error - Not Authenticated

```json
{
  "status": "error",
  "message": "Not authenticated"
}
```

### Dart Client Usage

```dart
Future<ClockInResult> clockIn({
  required String requestId,
  GeoPoint? location,
  double? accuracy,
}) async {
  final response = await supabase.rpc('clock_in', params: {
    'p_request_id': requestId,
    if (location != null) 'p_location': location.toJson(),
    if (accuracy != null) 'p_accuracy': accuracy,
  });
  return ClockInResult.fromJson(response);
}
```

---

## 2. clock_out

Idempotent clock-out operation with validation.

### Signature

```sql
clock_out(
  p_shift_id UUID,
  p_request_id UUID,
  p_location JSONB DEFAULT NULL,
  p_accuracy DECIMAL DEFAULT NULL
) RETURNS JSONB
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_shift_id | UUID | Yes | ID of the active shift to close |
| p_request_id | UUID | Yes | Client-generated idempotency key |
| p_location | JSONB | No | `{latitude: number, longitude: number}` |
| p_accuracy | DECIMAL | No | GPS accuracy in meters |

### Response

#### Success

```json
{
  "status": "success",
  "shift_id": "uuid",
  "clocked_out_at": "2026-01-08T17:30:00.000Z"
}
```

#### Already Processed (Idempotent)

```json
{
  "status": "already_processed",
  "shift_id": "uuid",
  "clocked_out_at": "2026-01-08T17:30:00.000Z"
}
```

#### Error - Shift Not Found

```json
{
  "status": "error",
  "message": "Shift not found"
}
```

#### Error - Not Authenticated

```json
{
  "status": "error",
  "message": "Not authenticated"
}
```

### Dart Client Usage

```dart
Future<ClockOutResult> clockOut({
  required String shiftId,
  required String requestId,
  GeoPoint? location,
  double? accuracy,
}) async {
  final response = await supabase.rpc('clock_out', params: {
    'p_shift_id': shiftId,
    'p_request_id': requestId,
    if (location != null) 'p_location': location.toJson(),
    if (accuracy != null) 'p_accuracy': accuracy,
  });
  return ClockOutResult.fromJson(response);
}
```

---

## 3. sync_gps_points

Batch insert GPS points with deduplication.

### Signature

```sql
sync_gps_points(p_points JSONB) RETURNS JSONB
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_points | JSONB | Yes | Array of GPS point objects |

### Point Object Schema

```json
{
  "client_id": "uuid",
  "shift_id": "uuid",
  "latitude": 37.7749,
  "longitude": -122.4194,
  "accuracy": 10.5,
  "captured_at": "2026-01-08T10:30:00.000Z",
  "device_id": "optional-device-id"
}
```

### Response

#### Success

```json
{
  "status": "success",
  "inserted": 5,
  "duplicates": 2
}
```

#### Error - Not Authenticated

```json
{
  "status": "error",
  "message": "Not authenticated"
}
```

### Dart Client Usage

```dart
Future<SyncResult> syncGpsPoints(List<GpsPoint> points) async {
  final response = await supabase.rpc('sync_gps_points', params: {
    'p_points': points.map((p) => p.toJson()).toList(),
  });
  return SyncResult.fromJson(response);
}
```

---

## REST API Contracts (Direct Table Access)

### Get Active Shift

```http
GET /rest/v1/shifts?employee_id=eq.{user_id}&status=eq.active&limit=1
Authorization: Bearer {access_token}
```

**Response**: Single shift object or empty array

### Get Shift History

```http
GET /rest/v1/shifts?employee_id=eq.{user_id}&status=eq.completed&order=clocked_in_at.desc&limit=50&offset=0
Authorization: Bearer {access_token}
```

**Response**: Array of shift objects, paginated

### Get Shift Detail

```http
GET /rest/v1/shifts?id=eq.{shift_id}&select=*
Authorization: Bearer {access_token}
```

**Response**: Single shift object

### Dart Client Usage

```dart
// Active shift
Future<Shift?> getActiveShift() async {
  final response = await supabase
    .from('shifts')
    .select()
    .eq('employee_id', userId)
    .eq('status', 'active')
    .maybeSingle();
  return response != null ? Shift.fromJson(response) : null;
}

// Shift history with pagination
Future<List<Shift>> getShiftHistory({int limit = 50, int offset = 0}) async {
  final response = await supabase
    .from('shifts')
    .select()
    .eq('employee_id', userId)
    .eq('status', 'completed')
    .order('clocked_in_at', ascending: false)
    .range(offset, offset + limit - 1);
  return response.map((json) => Shift.fromJson(json)).toList();
}
```

---

## Error Handling

All RPC functions return a consistent error structure:

```json
{
  "status": "error",
  "message": "Human-readable error description"
}
```

### Client-Side Handling

```dart
class RpcResult<T> {
  final String status;
  final T? data;
  final String? errorMessage;

  bool get isSuccess => status == 'success' || status == 'already_processed';
  bool get isError => status == 'error';
}
```

---

## Idempotency

Both `clock_in` and `clock_out` support idempotent requests:

1. Client generates a unique `request_id` (UUID) before making the call
2. If the same `request_id` is sent again, the function returns `already_processed` with the original result
3. This ensures offline retry safety - the same action won't create duplicate records

### Client Implementation

```dart
Future<ClockInResult> performClockIn() async {
  final requestId = uuid.v4();  // Generate once per user action

  // Save locally first
  await localDb.saveClockIn(requestId: requestId, ...);

  // Try to sync (may fail if offline)
  try {
    return await shiftService.clockIn(requestId: requestId, ...);
  } catch (e) {
    // Will retry later with same requestId
    return ClockInResult.pending(requestId);
  }
}
```
