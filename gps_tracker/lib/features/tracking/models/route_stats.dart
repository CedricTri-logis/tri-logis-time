import 'package:flutter/foundation.dart';

/// Summary statistics for a tracked route.
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

  /// Formatted duration string.
  String get formattedDuration {
    final d = duration;
    if (d == null) return '--';

    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }
}
