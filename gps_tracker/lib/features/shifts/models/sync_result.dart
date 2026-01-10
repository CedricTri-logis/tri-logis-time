/// Result of a sync operation with detailed success/failure counts.
class SyncResult {
  final int syncedShifts;
  final int failedShifts;
  final int syncedGpsPoints;
  final int failedGpsPoints;
  final int quarantinedRecords;
  final String? lastError;
  final Duration duration;
  final DateTime completedAt;

  SyncResult({
    this.syncedShifts = 0,
    this.failedShifts = 0,
    this.syncedGpsPoints = 0,
    this.failedGpsPoints = 0,
    this.quarantinedRecords = 0,
    this.lastError,
    Duration? duration,
    DateTime? completedAt,
  })  : duration = duration ?? Duration.zero,
        completedAt = completedAt ?? DateTime.now();

  /// Check if any errors occurred during sync.
  bool get hasErrors => failedShifts > 0 || failedGpsPoints > 0;

  /// Check if nothing was synced.
  bool get isEmpty =>
      syncedShifts == 0 &&
      failedShifts == 0 &&
      syncedGpsPoints == 0 &&
      failedGpsPoints == 0;

  /// Check if sync was fully successful.
  bool get isSuccess => !hasErrors && !isEmpty;

  /// Check if sync was partially successful.
  bool get isPartialSuccess =>
      (syncedShifts > 0 || syncedGpsPoints > 0) && hasErrors;

  /// Get total items synced.
  int get totalSynced => syncedShifts + syncedGpsPoints;

  /// Get total items failed.
  int get totalFailed => failedShifts + failedGpsPoints;

  /// Get total items processed.
  int get totalProcessed => totalSynced + totalFailed;

  /// Get success rate as percentage.
  double get successRate =>
      totalProcessed > 0 ? (totalSynced / totalProcessed) * 100 : 0;

  /// Create a copy with modified fields.
  SyncResult copyWith({
    int? syncedShifts,
    int? failedShifts,
    int? syncedGpsPoints,
    int? failedGpsPoints,
    int? quarantinedRecords,
    String? lastError,
    Duration? duration,
    DateTime? completedAt,
  }) {
    return SyncResult(
      syncedShifts: syncedShifts ?? this.syncedShifts,
      failedShifts: failedShifts ?? this.failedShifts,
      syncedGpsPoints: syncedGpsPoints ?? this.syncedGpsPoints,
      failedGpsPoints: failedGpsPoints ?? this.failedGpsPoints,
      quarantinedRecords: quarantinedRecords ?? this.quarantinedRecords,
      lastError: lastError ?? this.lastError,
      duration: duration ?? this.duration,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  /// Merge with another result (for combining batch results).
  SyncResult merge(SyncResult other) {
    return SyncResult(
      syncedShifts: syncedShifts + other.syncedShifts,
      failedShifts: failedShifts + other.failedShifts,
      syncedGpsPoints: syncedGpsPoints + other.syncedGpsPoints,
      failedGpsPoints: failedGpsPoints + other.failedGpsPoints,
      quarantinedRecords: quarantinedRecords + other.quarantinedRecords,
      lastError: other.lastError ?? lastError,
      duration: duration + other.duration,
      completedAt: other.completedAt,
    );
  }

  /// Create an empty/no-op result.
  factory SyncResult.empty() => SyncResult();

  /// Create a failure result.
  factory SyncResult.error(String message) => SyncResult(lastError: message);

  @override
  String toString() {
    return 'SyncResult(synced: $totalSynced, failed: $totalFailed, '
        'quarantined: $quarantinedRecords, duration: ${duration.inSeconds}s)';
  }
}
