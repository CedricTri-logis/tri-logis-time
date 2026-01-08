# Contract: RouteProvider

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Type**: State Management Contract (Riverpod)

---

## Overview

`RouteProvider` manages GPS point data for route visualization. It loads points from local database and provides them in a format suitable for map display.

---

## Provider Definition

### File Location
`lib/features/tracking/providers/route_provider.dart`

### Provider Type

```dart
/// Provides GPS points for a specific shift's route.
final routeProvider = FutureProvider.family<List<RoutePoint>, String>((ref, shiftId) async {
  final db = ref.read(localDatabaseProvider);
  final points = await db.getGpsPointsForShift(shiftId);

  return points
      .map((p) => RoutePoint.fromLocalGpsPoint(p))
      .toList()
    ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
});
```

---

## Supporting Providers

### shiftRoutePointsProvider

**Purpose**: Get route points for the currently viewed shift.

```dart
final shiftRoutePointsProvider = FutureProvider.family<List<RoutePoint>, String>((ref, shiftId) async {
  return ref.watch(routeProvider(shiftId).future);
});
```

### activeRouteProvider

**Purpose**: Get route points for currently active shift (real-time updates).

```dart
final activeRouteProvider = Provider<AsyncValue<List<RoutePoint>>>((ref) {
  final trackingState = ref.watch(trackingProvider);
  final activeShiftId = trackingState.activeShiftId;

  if (activeShiftId == null) {
    return const AsyncValue.data([]);
  }

  // Re-fetch when point count changes
  ref.watch(trackingProvider.select((s) => s.pointsCaptured));

  return ref.watch(routeProvider(activeShiftId));
});
```

### routeStatsProvider

**Purpose**: Computed statistics for a route.

```dart
final routeStatsProvider = Provider.family<RouteStats, List<RoutePoint>>((ref, points) {
  if (points.isEmpty) {
    return const RouteStats.empty();
  }

  final highAccuracyCount = points.where((p) => p.isHighAccuracy).length;
  final lowAccuracyCount = points.where((p) => p.isLowAccuracy).length;

  double totalDistance = 0;
  for (int i = 1; i < points.length; i++) {
    totalDistance += Geolocator.distanceBetween(
      points[i - 1].latitude,
      points[i - 1].longitude,
      points[i].latitude,
      points[i].longitude,
    );
  }

  return RouteStats(
    totalPoints: points.length,
    highAccuracyPoints: highAccuracyCount,
    lowAccuracyPoints: lowAccuracyCount,
    totalDistanceMeters: totalDistance,
    startTime: points.first.capturedAt,
    endTime: points.last.capturedAt,
  );
});
```

---

## RouteStats Model

```dart
@immutable
class RouteStats {
  final int totalPoints;
  final int highAccuracyPoints;
  final int lowAccuracyPoints;
  final double totalDistanceMeters;
  final DateTime? startTime;
  final DateTime? endTime;

  const RouteStats({
    required this.totalPoints,
    required this.highAccuracyPoints,
    required this.lowAccuracyPoints,
    required this.totalDistanceMeters,
    this.startTime,
    this.endTime,
  });

  const RouteStats.empty()
      : totalPoints = 0,
        highAccuracyPoints = 0,
        lowAccuracyPoints = 0,
        totalDistanceMeters = 0,
        startTime = null,
        endTime = null;

  /// Duration of the tracked route.
  Duration? get duration {
    if (startTime == null || endTime == null) return null;
    return endTime!.difference(startTime!);
  }

  /// Percentage of high-accuracy points.
  double get highAccuracyPercentage {
    if (totalPoints == 0) return 0;
    return (highAccuracyPoints / totalPoints) * 100;
  }

  /// Total distance in kilometers.
  double get totalDistanceKm => totalDistanceMeters / 1000;

  /// Formatted distance string.
  String get formattedDistance {
    if (totalDistanceMeters < 1000) {
      return '${totalDistanceMeters.toStringAsFixed(0)} m';
    }
    return '${totalDistanceKm.toStringAsFixed(2)} km';
  }
}
```

---

## Database Integration

### Required LocalDatabase Methods

```dart
/// Get all GPS points for a shift.
Future<List<LocalGpsPoint>> getGpsPointsForShift(String shiftId) async {
  final db = await database;
  final maps = await db.query(
    'local_gps_points',
    where: 'shift_id = ?',
    whereArgs: [shiftId],
    orderBy: 'captured_at ASC',
  );
  return maps.map((m) => LocalGpsPoint.fromMap(m)).toList();
}

/// Get GPS point count for a shift.
Future<int> getGpsPointCountForShift(String shiftId) async {
  final db = await database;
  final result = await db.rawQuery(
    'SELECT COUNT(*) as count FROM local_gps_points WHERE shift_id = ?',
    [shiftId],
  );
  return result.first['count'] as int;
}
```

---

## Map Bounds Calculation

### routeBoundsProvider

**Purpose**: Calculate map bounds to fit all points.

```dart
final routeBoundsProvider = Provider.family<LatLngBounds?, List<RoutePoint>>((ref, points) {
  if (points.isEmpty) return null;

  double minLat = points.first.latitude;
  double maxLat = points.first.latitude;
  double minLng = points.first.longitude;
  double maxLng = points.first.longitude;

  for (final point in points) {
    minLat = min(minLat, point.latitude);
    maxLat = max(maxLat, point.latitude);
    minLng = min(minLng, point.longitude);
    maxLng = max(maxLng, point.longitude);
  }

  // Add padding
  const padding = 0.001; // ~100m at equator
  return LatLngBounds(
    LatLng(minLat - padding, minLng - padding),
    LatLng(maxLat + padding, maxLng + padding),
  );
});
```

---

## Caching Strategy

The provider uses Riverpod's built-in caching:
- Points are cached per `shiftId`
- Cache invalidated when provider is disposed
- Active route re-fetches on `pointsCaptured` change

### Manual Invalidation

```dart
// Force refresh route data
ref.invalidate(routeProvider(shiftId));
```

---

## Performance Considerations

| Points | Expected Load Time | Notes |
|--------|-------------------|-------|
| < 100 | < 50ms | Typical shift |
| 100-500 | < 200ms | Long shift or high frequency |
| 500+ | < 500ms | Exceptional case |

For routes with 500+ points, consider:
- Pagination for list views
- Point simplification for map display (Douglas-Peucker algorithm)

---

## Testing Requirements

| Test Case | Type | Verification |
|-----------|------|--------------|
| Empty route returns empty list | Unit | `[]` for shift with no points |
| Points sorted chronologically | Unit | `capturedAt` ascending |
| Route stats calculated correctly | Unit | Distance, counts accurate |
| Active route updates on new point | Integration | Provider rebuilds |
| Bounds calculated correctly | Unit | All points within bounds |
