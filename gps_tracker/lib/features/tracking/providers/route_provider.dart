import 'dart:math';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../shifts/providers/shift_provider.dart';
import '../models/route_point.dart';
import '../models/route_stats.dart';
import 'tracking_provider.dart';

/// Provides GPS points for a specific shift's route.
final routeProvider =
    FutureProvider.family<List<RoutePoint>, String>((ref, shiftId) async {
  final db = ref.read(localDatabaseProvider);
  final points = await db.getGpsPointsForShift(shiftId);

  return points
      .map((p) => RoutePoint.fromLocalGpsPoint(p))
      .toList()
    ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
});

/// Get route points for the currently viewed shift.
final shiftRoutePointsProvider =
    FutureProvider.family<List<RoutePoint>, String>((ref, shiftId) async {
  return ref.watch(routeProvider(shiftId).future);
});

/// Get route points for currently active shift (real-time updates).
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

/// Computed statistics for a route.
final routeStatsProvider =
    Provider.family<RouteStats, List<RoutePoint>>((ref, points) {
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

/// Calculate map bounds to fit all points.
final routeBoundsProvider =
    Provider.family<LatLngBounds?, List<RoutePoint>>((ref, points) {
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
