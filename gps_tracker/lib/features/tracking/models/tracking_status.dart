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
