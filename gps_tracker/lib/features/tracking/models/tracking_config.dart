import 'package:flutter/foundation.dart';

/// Configuration settings for background GPS tracking.
@immutable
class TrackingConfig {
  /// GPS capture interval when moving or recently stopped (in seconds).
  /// 120s stationary interval only activates after 5-minute confirmed stop.
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
    this.activeIntervalSeconds = 10, // 10s for all active states (moving or recently stopped)
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

  /// Compute capture interval: 10s active, 120s stationary.
  ///
  /// Simplified two-tier system:
  /// - Active (any speed, or recently stopped < 5 min): 10s
  /// - Confirmed stationary (> 5 min at same spot): 120s
  ///
  /// Stationary detection is handled by the background handler's
  /// `_checkStationaryState()`, not by speed thresholds.
  /// This method returns [activeIntervalSeconds] (10s) as the default.
  int intervalForSpeed(double? speedMs) {
    if (speedMs == null || speedMs < 0) return activeIntervalSeconds;
    if (speedMs < 0.5) return stationaryIntervalSeconds;
    return activeIntervalSeconds;
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
        activeIntervalSeconds: json['active_interval_seconds'] as int? ?? 10,
        stationaryIntervalSeconds: json['stationary_interval_seconds'] as int? ?? 120,
        distanceFilterMeters: json['distance_filter_meters'] as int? ?? 0,
        highAccuracyThreshold: (json['high_accuracy_threshold'] as num?)?.toDouble() ?? 50.0,
        lowAccuracyThreshold: (json['low_accuracy_threshold'] as num?)?.toDouble() ?? 100.0,
        adaptivePolling: json['adaptive_polling'] as bool? ?? true,
      );
}
