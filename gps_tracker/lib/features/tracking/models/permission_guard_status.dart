/// Overall status for the permission guard UI.
enum PermissionGuardStatus {
  /// All permissions granted, no action needed.
  allGranted,

  /// Partial permissions (while-in-use only) - warning but functional.
  partialPermission,

  /// No app permission granted - action required.
  permissionRequired,

  /// Permission permanently denied - requires settings navigation.
  permanentlyDenied,

  /// Device location services disabled - requires device settings.
  deviceServicesDisabled,

  /// Battery optimization enabled (Android) - optional action.
  batteryOptimizationRequired,

  /// Precise/exact location not enabled (Android 12+) - action required.
  preciseLocationRequired,
}
