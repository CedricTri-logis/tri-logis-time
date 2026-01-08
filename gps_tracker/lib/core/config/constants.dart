/// Application-wide constants
class AppConstants {
  AppConstants._();

  /// App name displayed in UI
  static const String appName = 'GPS Clock-In Tracker';

  /// GPS tracking interval in minutes during active shift
  static const int gpsTrackingIntervalMinutes = 5;

  /// Minimum GPS accuracy in meters to accept a reading
  static const double minGpsAccuracyMeters = 100.0;

  /// Distance filter for GPS updates in meters
  static const double gpsDistanceFilterMeters = 100.0;

  /// Maximum retry attempts for sync operations
  static const int maxSyncRetries = 3;

  /// Timeout for network requests in seconds
  static const int networkTimeoutSeconds = 30;

  /// Local database name
  static const String localDatabaseName = 'gps_tracker.db';

  /// Sync status values
  static const String syncStatusPending = 'pending';
  static const String syncStatusSynced = 'synced';
  static const String syncStatusFailed = 'failed';

  /// Shift status values
  static const String shiftStatusActive = 'active';
  static const String shiftStatusCompleted = 'completed';

  /// Employee status values
  static const String employeeStatusActive = 'active';
  static const String employeeStatusInactive = 'inactive';
  static const String employeeStatusSuspended = 'suspended';
}
