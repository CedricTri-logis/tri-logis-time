/// Application-wide constants
class AppConstants {
  AppConstants._();

  /// App name displayed in UI
  static const String appName = 'Tri-Logis Pointage';

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

  // --- Authentication Constants ---

  /// Maximum sign-in attempts before rate limiting
  static const int authMaxAttempts = 5;

  /// Rate limit window in minutes
  static const int authRateLimitWindowMinutes = 15;

  /// Minimum password length
  static const int authMinPasswordLength = 8;

  // --- Auth Error Messages ---

  /// Error message for invalid credentials
  static const String authErrorInvalidCredentials = 'Invalid email or password';

  /// Error message for email not verified
  static const String authErrorEmailNotVerified = 'Please verify your email first';

  /// Error message for account already exists
  static const String authErrorAccountExists = 'An account with this email already exists';

  /// Error message for weak password
  static const String authErrorWeakPassword = 'Password must be at least 8 characters with letters and numbers';

  /// Error message for rate limit exceeded
  static const String authErrorRateLimited = 'Too many attempts. Please wait a few minutes.';

  /// Error message for network issues
  static const String authErrorNetwork = 'Network error. Please check your connection.';

  /// Generic auth error message
  static const String authErrorGeneric = 'Authentication failed. Please try again.';
}
