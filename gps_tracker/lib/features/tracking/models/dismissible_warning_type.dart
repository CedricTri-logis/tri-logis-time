/// Warning types that can be dismissed by the user within a session.
enum DismissibleWarningType {
  /// "While in use" permission warning (partial permission).
  partialPermission,

  /// Battery optimization warning (Android only).
  batteryOptimization,
}
