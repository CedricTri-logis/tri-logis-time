import 'package:flutter/foundation.dart';

/// Configuration settings for background GPS tracking.
@immutable
class TrackingConfig {
  /// GPS capture interval when moving (in seconds). Used as fallback when speed data unavailable.
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
    this.activeIntervalSeconds = 60, // Fallback when speed unavailable
    this.stationaryIntervalSeconds = 120, // 2 min when not moving (was 300s)
    this.distanceFilterMeters = 0, // 0 = continuous updates (filtered by interval logic)
    this.highAccuracyThreshold = 50.0, // SC-003: 95% under 50m
    this.lowAccuracyThreshold = 100.0, // Points over 100m flagged
    this.adaptivePolling = true, // FR-017, FR-018
  });

  /// Default configuration.
  static const TrackingConfig defaultConfig = TrackingConfig();

  /// Battery-saver configuration with longer intervals.
  static const TrackingConfig batterySaver = TrackingConfig(
    activeIntervalSeconds: 120, // 2 minutes
    stationaryIntervalSeconds: 600, // 10 minutes
    distanceFilterMeters: 10,
  );

  /// Compute the optimal capture interval based on current speed.
  ///
  /// Uses speed-based tiers for adaptive frequency:
  /// - Stationary (< 0.5 m/s): 120s — battery saving
  /// - Walking (0.5 - 2.0 m/s): 30s — detailed pedestrian tracking
  /// - Vehicle/city (2.0 - 8.0 m/s): 15s — precise route following
  /// - Vehicle/highway (> 8.0 m/s): 10s — maximum precision
  ///
  /// Returns [activeIntervalSeconds] as fallback when speed is null or negative.
  int intervalForSpeed(double? speedMs) {
    if (speedMs == null || speedMs < 0) return activeIntervalSeconds;
    if (speedMs < 0.5) return stationaryIntervalSeconds;
    if (speedMs < 2.0) return 30;
    if (speedMs < 8.0) return 15;
    return 10;
  }

  TrackingConfig copyWith({
    int? activeIntervalSeconds,
    int? stationaryIntervalSeconds,
    int? distanceFilterMeters,
    double? highAccuracyThreshold,
    double? lowAccuracyThreshold,
    bool? adaptivePolling,
  }) =>
      TrackingConfig(
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
        activeIntervalSeconds: json['active_interval_seconds'] as int? ?? 60,
        stationaryIntervalSeconds: json['stationary_interval_seconds'] as int? ?? 120,
        distanceFilterMeters: json['distance_filter_meters'] as int? ?? 0,
        highAccuracyThreshold: (json['high_accuracy_threshold'] as num?)?.toDouble() ?? 50.0,
        lowAccuracyThreshold: (json['low_accuracy_threshold'] as num?)?.toDouble() ?? 100.0,
        adaptivePolling: json['adaptive_polling'] as bool? ?? true,
      );
}
