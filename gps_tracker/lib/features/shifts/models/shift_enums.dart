/// Status of a shift in the system.
enum ShiftStatus {
  active,
  completed;

  String toJson() => name;

  static ShiftStatus fromJson(String json) => ShiftStatus.values.firstWhere(
        (e) => e.name == json,
        orElse: () => ShiftStatus.active,
      );
}

/// Sync status for local-first data.
enum SyncStatus {
  pending,
  syncing,
  synced,
  error;

  String toJson() => name;

  static SyncStatus fromJson(String json) => SyncStatus.values.firstWhere(
        (e) => e.name == json,
        orElse: () => SyncStatus.pending,
      );
}

/// Type of clock event.
enum ClockEventType {
  clockIn,
  clockOut;
}
