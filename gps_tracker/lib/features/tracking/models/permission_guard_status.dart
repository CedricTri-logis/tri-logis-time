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

  /// App is in restricted/rare standby bucket (Samsung sleeping or Android hibernation).
  appStandbyRestricted,

  /// Precise/exact location not enabled (Android 12+) - action required.
  preciseLocationRequired,
}
