import 'package:flutter/foundation.dart';

import '../../shifts/models/local_gps_point.dart';

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
    required this.capturedAt,
    this.accuracy,
  });

  /// Whether this point has low accuracy (>100m).
  bool get isLowAccuracy => accuracy != null && accuracy! > 100;

  /// Whether this point has high accuracy (<=50m).
  bool get isHighAccuracy => accuracy != null && accuracy! <= 50;

  /// Whether this point has medium accuracy (50-100m).
  bool get isMediumAccuracy =>
      accuracy != null && accuracy! > 50 && accuracy! <= 100;

  /// Create from LocalGpsPoint.
  factory RoutePoint.fromLocalGpsPoint(LocalGpsPoint localGpsPoint) =>
      RoutePoint(
        id: localGpsPoint.id,
        latitude: localGpsPoint.latitude,
        longitude: localGpsPoint.longitude,
        accuracy: localGpsPoint.accuracy,
        capturedAt: localGpsPoint.capturedAt,
      );
}
