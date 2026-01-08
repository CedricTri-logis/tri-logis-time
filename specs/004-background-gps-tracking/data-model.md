# Data Model: Background GPS Tracking

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Status**: Complete

---

## Overview

This document defines data models for the background GPS tracking feature. The design extends existing models where possible and introduces new models only where necessary.

---

## Existing Entities (No Changes Required)

### LocalGpsPoint

**Location**: `lib/features/shifts/models/local_gps_point.dart`
**Purpose**: Stores GPS captures in local SQLCipher database with sync tracking.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | UUID, client-generated (used as `client_id` in Supabase) |
| `shiftId` | `String` | Foreign key to shift |
| `employeeId` | `String` | Employee identifier |
| `latitude` | `double` | Latitude coordinate (-90 to 90) |
| `longitude` | `double` | Longitude coordinate (-180 to 180) |
| `accuracy` | `double?` | GPS accuracy in meters |
| `capturedAt` | `DateTime` | When the GPS point was captured |
| `deviceId` | `String?` | Device identifier |
| `syncStatus` | `String` | "pending", "syncing", "synced", "error" |
| `createdAt` | `DateTime` | Record creation timestamp |

**Status**: Fully suitable for background tracking - no modifications needed.

### Shift

**Location**: `lib/features/shifts/models/shift.dart`
**Purpose**: Represents work session from clock-in to clock-out.

**Status**: No modifications needed. GPS points reference shift via `shiftId`.

### SyncStatus (Enum)

**Location**: `lib/features/shifts/models/shift_enums.dart`
**Values**: `pending`, `syncing`, `synced`, `error`

**Status**: Reused for GPS point sync tracking - no modifications needed.

---

## New Entities

### TrackingConfig

**Location**: `lib/features/tracking/models/tracking_config.dart`
**Purpose**: Configuration for background GPS tracking behavior.

```dart
import 'package:flutter/foundation.dart';

/// Configuration settings for background GPS tracking.
@immutable
class TrackingConfig {
  /// GPS capture interval when moving (in seconds).
  final int activeIntervalSeconds;

  /// GPS capture interval when stationary (in seconds).
  final int stationaryIntervalSeconds;

  /// Distance filter for position updates (in meters).
  final int distanceFilterMeters;

  /// Accuracy threshold for high-quality points (in meters).
  final double highAccuracyThreshold;

  /// Accuracy threshold below which points are considered low-quality (in meters).
  final double lowAccuracyThreshold;

  /// Whether to adapt polling based on movement state.
  final bool adaptivePolling;

  const TrackingConfig({
    this.activeIntervalSeconds = 300,      // 5 minutes (FR-003 default)
    this.stationaryIntervalSeconds = 600,  // 10 minutes when not moving
    this.distanceFilterMeters = 10,        // 10m movement triggers update
    this.highAccuracyThreshold = 50.0,     // SC-003: 95% under 50m
    this.lowAccuracyThreshold = 100.0,     // Points over 100m flagged
    this.adaptivePolling = true,           // FR-017, FR-018
  });

  /// Default configuration per FR-003 (5-minute interval).
  static const TrackingConfig defaultConfig = TrackingConfig();

  /// Battery-saver configuration with longer intervals.
  static const TrackingConfig batterySaver = TrackingConfig(
    activeIntervalSeconds: 600,      // 10 minutes
    stationaryIntervalSeconds: 900,  // 15 minutes
    distanceFilterMeters: 20,
  );

  TrackingConfig copyWith({
    int? activeIntervalSeconds,
    int? stationaryIntervalSeconds,
    int? distanceFilterMeters,
    double? highAccuracyThreshold,
    double? lowAccuracyThreshold,
    bool? adaptivePolling,
  }) => TrackingConfig(
    activeIntervalSeconds: activeIntervalSeconds ?? this.activeIntervalSeconds,
    stationaryIntervalSeconds: stationaryIntervalSeconds ?? this.stationaryIntervalSeconds,
    distanceFilterMeters: distanceFilterMeters ?? this.distanceFilterMeters,
    highAccuracyThreshold: highAccuracyThreshold ?? this.highAccuracyThreshold,
    lowAccuracyThreshold: lowAccuracyThreshold ?? this.lowAccuracyThreshold,
    adaptivePolling: adaptivePolling ?? this.adaptivePolling,
  );

  Map<String, dynamic> toJson() => {
    'active_interval_seconds': activeIntervalSeconds,
    'stationary_interval_seconds': stationaryIntervalSeconds,
    'distance_filter_meters': distanceFilterMeters,
    'high_accuracy_threshold': highAccuracyThreshold,
    'low_accuracy_threshold': lowAccuracyThreshold,
    'adaptive_polling': adaptivePolling,
  };

  factory TrackingConfig.fromJson(Map<String, dynamic> json) => TrackingConfig(
    activeIntervalSeconds: json['active_interval_seconds'] as int? ?? 300,
    stationaryIntervalSeconds: json['stationary_interval_seconds'] as int? ?? 600,
    distanceFilterMeters: json['distance_filter_meters'] as int? ?? 10,
    highAccuracyThreshold: (json['high_accuracy_threshold'] as num?)?.toDouble() ?? 50.0,
    lowAccuracyThreshold: (json['low_accuracy_threshold'] as num?)?.toDouble() ?? 100.0,
    adaptivePolling: json['adaptive_polling'] as bool? ?? true,
  );
}
```

**Validation Rules**:
- `activeIntervalSeconds` must be >= 60 (1 minute minimum)
- `stationaryIntervalSeconds` must be >= `activeIntervalSeconds`
- `distanceFilterMeters` must be >= 5
- `highAccuracyThreshold` must be < `lowAccuracyThreshold`

---

### TrackingStatus (Enum)

**Location**: `lib/features/tracking/models/tracking_status.dart`
**Purpose**: Represents the current state of background tracking.

```dart
/// Current status of background GPS tracking.
enum TrackingStatus {
  /// Tracking is not active (no active shift or tracking stopped).
  stopped,

  /// Tracking is starting up.
  starting,

  /// Tracking is actively capturing GPS points.
  running,

  /// Tracking is temporarily paused (e.g., GPS unavailable).
  paused,

  /// Tracking encountered an error.
  error;

  /// Whether tracking is considered active.
  bool get isActive => this == running || this == paused;

  /// Human-readable description.
  String get displayName {
    switch (this) {
      case TrackingStatus.stopped:
        return 'Stopped';
      case TrackingStatus.starting:
        return 'Starting...';
      case TrackingStatus.running:
        return 'Tracking Active';
      case TrackingStatus.paused:
        return 'Paused';
      case TrackingStatus.error:
        return 'Error';
    }
  }
}
```

---

### TrackingState

**Location**: `lib/features/tracking/models/tracking_state.dart`
**Purpose**: Complete state snapshot for tracking provider.

```dart
import 'package:flutter/foundation.dart';
import 'tracking_config.dart';
import 'tracking_status.dart';

/// Complete state of background GPS tracking.
@immutable
class TrackingState {
  /// Current tracking status.
  final TrackingStatus status;

  /// ID of the shift being tracked (null if not tracking).
  final String? activeShiftId;

  /// Number of GPS points captured this session.
  final int pointsCaptured;

  /// Timestamp of last successful GPS capture.
  final DateTime? lastCaptureTime;

  /// Last captured latitude.
  final double? lastLatitude;

  /// Last captured longitude.
  final double? lastLongitude;

  /// Last capture accuracy in meters.
  final double? lastAccuracy;

  /// Current tracking configuration.
  final TrackingConfig config;

  /// Error message if status is error.
  final String? errorMessage;

  /// Whether currently in stationary mode (reduced polling).
  final bool isStationary;

  const TrackingState({
    this.status = TrackingStatus.stopped,
    this.activeShiftId,
    this.pointsCaptured = 0,
    this.lastCaptureTime,
    this.lastLatitude,
    this.lastLongitude,
    this.lastAccuracy,
    this.config = const TrackingConfig(),
    this.errorMessage,
    this.isStationary = false,
  });

  /// Initial state before any tracking.
  static const TrackingState initial = TrackingState();

  /// Whether tracking is currently running.
  bool get isTracking => status == TrackingStatus.running;

  /// Whether last capture had high accuracy.
  bool get hasHighAccuracy =>
      lastAccuracy != null && lastAccuracy! <= config.highAccuracyThreshold;

  /// Whether last capture had low accuracy.
  bool get hasLowAccuracy =>
      lastAccuracy != null && lastAccuracy! > config.lowAccuracyThreshold;

  TrackingState copyWith({
    TrackingStatus? status,
    String? activeShiftId,
    int? pointsCaptured,
    DateTime? lastCaptureTime,
    double? lastLatitude,
    double? lastLongitude,
    double? lastAccuracy,
    TrackingConfig? config,
    String? errorMessage,
    bool? isStationary,
  }) => TrackingState(
    status: status ?? this.status,
    activeShiftId: activeShiftId ?? this.activeShiftId,
    pointsCaptured: pointsCaptured ?? this.pointsCaptured,
    lastCaptureTime: lastCaptureTime ?? this.lastCaptureTime,
    lastLatitude: lastLatitude ?? this.lastLatitude,
    lastLongitude: lastLongitude ?? this.lastLongitude,
    lastAccuracy: lastAccuracy ?? this.lastAccuracy,
    config: config ?? this.config,
    errorMessage: errorMessage ?? this.errorMessage,
    isStationary: isStationary ?? this.isStationary,
  );

  /// Create state indicating tracking has started for a shift.
  TrackingState startTracking(String shiftId) => copyWith(
    status: TrackingStatus.starting,
    activeShiftId: shiftId,
    pointsCaptured: 0,
    lastCaptureTime: null,
    errorMessage: null,
  );

  /// Create state with a new GPS point captured.
  TrackingState recordPoint({
    required double latitude,
    required double longitude,
    required double? accuracy,
    required DateTime capturedAt,
  }) => copyWith(
    status: TrackingStatus.running,
    pointsCaptured: pointsCaptured + 1,
    lastCaptureTime: capturedAt,
    lastLatitude: latitude,
    lastLongitude: longitude,
    lastAccuracy: accuracy,
    errorMessage: null,
  );

  /// Create state indicating tracking has stopped.
  TrackingState stopTracking() => const TrackingState();

  /// Create error state.
  TrackingState withError(String message) => copyWith(
    status: TrackingStatus.error,
    errorMessage: message,
  );
}
```

**State Transitions**:
```
stopped --[clock in]--> starting --[first point]--> running
running --[GPS error]--> paused --[GPS restored]--> running
running --[clock out]--> stopped
any --[fatal error]--> error
```

---

### LocationPermissionState

**Location**: `lib/features/tracking/models/location_permission_state.dart`
**Purpose**: Tracks location permission status per spec entity "Location Permissions State".

```dart
import 'package:flutter/foundation.dart';

/// Permission level for location access.
enum LocationPermissionLevel {
  /// Permission has not been requested.
  notDetermined,

  /// User denied permission.
  denied,

  /// User denied permission permanently.
  deniedForever,

  /// Permission granted while app is in use.
  whileInUse,

  /// Permission granted always (including background).
  always,
}

/// Tracks current location permission status.
@immutable
class LocationPermissionState {
  /// Current permission level.
  final LocationPermissionLevel level;

  /// When permission was last checked.
  final DateTime lastChecked;

  /// Whether background tracking is possible.
  bool get canTrackInBackground => level == LocationPermissionLevel.always;

  /// Whether any location access is available.
  bool get hasAnyPermission =>
      level == LocationPermissionLevel.whileInUse ||
      level == LocationPermissionLevel.always;

  /// Whether user can be prompted for permission.
  bool get canRequestPermission =>
      level == LocationPermissionLevel.notDetermined ||
      level == LocationPermissionLevel.denied;

  const LocationPermissionState({
    required this.level,
    required this.lastChecked,
  });

  static LocationPermissionState initial() => LocationPermissionState(
    level: LocationPermissionLevel.notDetermined,
    lastChecked: DateTime.now(),
  );

  LocationPermissionState copyWith({
    LocationPermissionLevel? level,
    DateTime? lastChecked,
  }) => LocationPermissionState(
    level: level ?? this.level,
    lastChecked: lastChecked ?? this.lastChecked,
  );
}
```

---

### RoutePoint

**Location**: `lib/features/tracking/models/route_point.dart`
**Purpose**: Simplified GPS point for route visualization (derived from LocalGpsPoint).

```dart
import 'package:flutter/foundation.dart';

/// Simplified GPS point for route map display.
@immutable
class RoutePoint {
  final String id;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;

  const RoutePoint({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.accuracy,
    required this.capturedAt,
  });

  /// Whether this point has low accuracy (>100m).
  bool get isLowAccuracy => accuracy != null && accuracy! > 100;

  /// Whether this point has high accuracy (<=50m).
  bool get isHighAccuracy => accuracy != null && accuracy! <= 50;

  /// Create from LocalGpsPoint.
  factory RoutePoint.fromLocalGpsPoint(dynamic localGpsPoint) => RoutePoint(
    id: localGpsPoint.id as String,
    latitude: localGpsPoint.latitude as double,
    longitude: localGpsPoint.longitude as double,
    accuracy: localGpsPoint.accuracy as double?,
    capturedAt: localGpsPoint.capturedAt as DateTime,
  );
}
```

---

## Database Schema

### Existing Table: local_gps_points (SQLite/SQLCipher)

**Status**: No schema changes required.

```sql
CREATE TABLE local_gps_points (
  id TEXT PRIMARY KEY,
  shift_id TEXT NOT NULL,
  employee_id TEXT NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  accuracy REAL,
  captured_at TEXT NOT NULL,
  device_id TEXT,
  sync_status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL,
  FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
);

CREATE INDEX idx_gps_points_shift_id ON local_gps_points(shift_id);
CREATE INDEX idx_gps_points_sync_status ON local_gps_points(sync_status);
```

### Existing Table: gps_points (Supabase PostgreSQL)

**Status**: No schema changes required.

```sql
CREATE TABLE gps_points (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  client_id UUID UNIQUE NOT NULL,  -- Maps to LocalGpsPoint.id
  shift_id UUID NOT NULL REFERENCES shifts(id),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  latitude DECIMAL(10,7) NOT NULL,
  longitude DECIMAL(10,7) NOT NULL,
  accuracy DECIMAL(6,2),
  captured_at TIMESTAMP WITH TIME ZONE NOT NULL,
  received_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  device_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

---

## Entity Relationships

```
Shift (1) ----< (N) LocalGpsPoint
  |                     |
  | (sync)              | (sync via client_id)
  v                     v
shifts (Supabase)  gps_points (Supabase)
```

- One Shift has many LocalGpsPoints
- GPS points are captured locally, synced to Supabase via `sync_gps_points` RPC
- `client_id` in Supabase matches `id` in local storage (idempotent sync)

---

## Data Flow

### GPS Point Capture Flow

```
1. Background task captures position (geolocator)
2. Create LocalGpsPoint with UUID, timestamp, coords, accuracy
3. Insert into local_gps_points table (SQLCipher)
4. Send update to main isolate via FlutterForegroundTask
5. Update TrackingState.pointsCaptured
6. SyncService batches pending points
7. Call sync_gps_points RPC when connectivity available
8. Mark local points as synced
```

### Permission Check Flow

```
1. User initiates clock-in
2. Check Geolocator.checkPermission()
3. If denied, request Geolocator.requestPermission()
4. If whileInUse, show prompt for "Always" permission
5. If deniedForever, show settings guidance
6. Update LocationPermissionState
7. Proceed with clock-in only if canTrackInBackground
```

---

## Validation Rules Summary

| Entity | Field | Validation |
|--------|-------|------------|
| TrackingConfig | activeIntervalSeconds | >= 60 |
| TrackingConfig | stationaryIntervalSeconds | >= activeIntervalSeconds |
| TrackingConfig | distanceFilterMeters | >= 5 |
| LocalGpsPoint | latitude | -90 to 90 |
| LocalGpsPoint | longitude | -180 to 180 |
| LocalGpsPoint | accuracy | >= 0 (nullable) |
| LocalGpsPoint | capturedAt | Not in future |
| RoutePoint | latitude | -90 to 90 |
| RoutePoint | longitude | -180 to 180 |

---

## Storage Capacity

Per FR-016 (48 hours of local storage):

| Interval | Points/Hour | 48-Hour Points | Size (est.) |
|----------|-------------|----------------|-------------|
| 5 min | 12 | 576 | ~115 KB |
| 2 min | 30 | 1,440 | ~288 KB |
| 1 min | 60 | 2,880 | ~576 KB |

SQLite easily handles these volumes. No storage concerns for 48-hour retention.
