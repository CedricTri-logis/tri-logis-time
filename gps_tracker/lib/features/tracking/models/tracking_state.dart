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

  /// Whether GPS signal has been lost (background handler detected no position).
  final bool gpsSignalLost;

  /// Whether background GPS tracking has been verified (first point received).
  final bool trackingVerified;

  /// Whether tracking start failed (no GPS point received within timeout).
  final bool trackingStartFailed;

  /// Whether an auto clock-out was triggered due to tracking verification failure.
  final bool trackingAutoClockOutOccurred;

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
    this.gpsSignalLost = false,
    this.trackingVerified = false,
    this.trackingStartFailed = false,
    this.trackingAutoClockOutOccurred = false,
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
    bool? gpsSignalLost,
    bool? trackingVerified,
    bool? trackingStartFailed,
    bool? trackingAutoClockOutOccurred,
    bool clearError = false,
    bool clearActiveShift = false,
  }) =>
      TrackingState(
        status: status ?? this.status,
        activeShiftId: clearActiveShift ? null : (activeShiftId ?? this.activeShiftId),
        pointsCaptured: pointsCaptured ?? this.pointsCaptured,
        lastCaptureTime: lastCaptureTime ?? this.lastCaptureTime,
        lastLatitude: lastLatitude ?? this.lastLatitude,
        lastLongitude: lastLongitude ?? this.lastLongitude,
        lastAccuracy: lastAccuracy ?? this.lastAccuracy,
        config: config ?? this.config,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        isStationary: isStationary ?? this.isStationary,
        gpsSignalLost: gpsSignalLost ?? this.gpsSignalLost,
        trackingVerified: trackingVerified ?? this.trackingVerified,
        trackingStartFailed: trackingStartFailed ?? this.trackingStartFailed,
        trackingAutoClockOutOccurred: trackingAutoClockOutOccurred ?? this.trackingAutoClockOutOccurred,
      );

  /// Create state indicating tracking has started for a shift.
  TrackingState startTracking(String shiftId) => copyWith(
        status: TrackingStatus.starting,
        activeShiftId: shiftId,
        pointsCaptured: 0,
        lastCaptureTime: null,
        lastLatitude: null,
        lastLongitude: null,
        lastAccuracy: null,
        trackingVerified: false,
        trackingStartFailed: false,
        trackingAutoClockOutOccurred: false,
        clearError: true,
      );

  /// Create state with a new GPS point captured.
  TrackingState recordPoint({
    required double latitude,
    required double longitude,
    required double? accuracy,
    required DateTime capturedAt,
  }) =>
      copyWith(
        status: TrackingStatus.running,
        pointsCaptured: pointsCaptured + 1,
        lastCaptureTime: capturedAt,
        lastLatitude: latitude,
        lastLongitude: longitude,
        lastAccuracy: accuracy,
        trackingVerified: true,
        trackingStartFailed: false,
        clearError: true,
      );

  /// Create state indicating tracking has stopped.
  TrackingState stopTracking() => const TrackingState();

  /// Create error state.
  TrackingState withError(String message) => copyWith(
        status: TrackingStatus.error,
        errorMessage: message,
      );

  /// Create paused state.
  TrackingState pause() => copyWith(status: TrackingStatus.paused);

  /// Resume from paused state.
  TrackingState resume() => copyWith(status: TrackingStatus.running);
}
