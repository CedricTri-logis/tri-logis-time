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
    this.activeIntervalSeconds = 300, // 5 minutes (FR-003)
    this.stationaryIntervalSeconds = 600, // 10 minutes
    this.distanceFilterMeters = 10, // 10m movement triggers update
    this.highAccuracyThreshold = 50.0, // SC-003: 95% under 50m
    this.lowAccuracyThreshold = 100.0, // Points over 100m flagged
    this.adaptivePolling = true, // FR-017, FR-018
  });

  /// Default configuration per FR-003 (5-minute interval).
  static const TrackingConfig defaultConfig = TrackingConfig();

  /// Battery-saver configuration with longer intervals.
  static const TrackingConfig batterySaver = TrackingConfig(
    activeIntervalSeconds: 600, // 10 minutes
    stationaryIntervalSeconds: 900, // 15 minutes
    distanceFilterMeters: 20,
  );

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
        activeIntervalSeconds: json['active_interval_seconds'] as int? ?? 300,
        stationaryIntervalSeconds: json['stationary_interval_seconds'] as int? ?? 600,
        distanceFilterMeters: json['distance_filter_meters'] as int? ?? 10,
        highAccuracyThreshold: (json['high_accuracy_threshold'] as num?)?.toDouble() ?? 50.0,
        lowAccuracyThreshold: (json['low_accuracy_threshold'] as num?)?.toDouble() ?? 100.0,
        adaptivePolling: json['adaptive_polling'] as bool? ?? true,
      );
}
