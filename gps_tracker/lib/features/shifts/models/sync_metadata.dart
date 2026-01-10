/// Model for persistent sync state metadata.
/// Singleton pattern - only one row exists in the database.
class SyncMetadata {
  static const String tableName = 'sync_metadata';
  static const String singletonId = 'singleton';

  final String id;
  final DateTime? lastSyncAttempt;
  final DateTime? lastSuccessfulSync;
  final int consecutiveFailures;
  final int currentBackoffSeconds;
  final bool syncInProgress;
  final String? lastError;
  final int pendingShiftsCount;
  final int pendingGpsPointsCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SyncMetadata({
    this.id = singletonId,
    this.lastSyncAttempt,
    this.lastSuccessfulSync,
    this.consecutiveFailures = 0,
    this.currentBackoffSeconds = 0,
    this.syncInProgress = false,
    this.lastError,
    this.pendingShiftsCount = 0,
    this.pendingGpsPointsCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Check if there is pending data to sync.
  bool get hasPendingData =>
      pendingShiftsCount > 0 || pendingGpsPointsCount > 0;

  /// Check if there is an error state.
  bool get hasError => lastError != null && lastError!.isNotEmpty;

  /// Get the current backoff duration.
  Duration get backoffDuration => Duration(seconds: currentBackoffSeconds);

  /// Total pending items count.
  int get totalPending => pendingShiftsCount + pendingGpsPointsCount;

  /// Create a copy with modified fields.
  SyncMetadata copyWith({
    String? id,
    DateTime? lastSyncAttempt,
    DateTime? lastSuccessfulSync,
    int? consecutiveFailures,
    int? currentBackoffSeconds,
    bool? syncInProgress,
    String? lastError,
    bool clearError = false,
    int? pendingShiftsCount,
    int? pendingGpsPointsCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SyncMetadata(
      id: id ?? this.id,
      lastSyncAttempt: lastSyncAttempt ?? this.lastSyncAttempt,
      lastSuccessfulSync: lastSuccessfulSync ?? this.lastSuccessfulSync,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      currentBackoffSeconds:
          currentBackoffSeconds ?? this.currentBackoffSeconds,
      syncInProgress: syncInProgress ?? this.syncInProgress,
      lastError: clearError ? null : (lastError ?? this.lastError),
      pendingShiftsCount: pendingShiftsCount ?? this.pendingShiftsCount,
      pendingGpsPointsCount:
          pendingGpsPointsCount ?? this.pendingGpsPointsCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Convert to database map.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'last_sync_attempt': lastSyncAttempt?.toUtc().toIso8601String(),
      'last_successful_sync': lastSuccessfulSync?.toUtc().toIso8601String(),
      'consecutive_failures': consecutiveFailures,
      'current_backoff_seconds': currentBackoffSeconds,
      'sync_in_progress': syncInProgress ? 1 : 0,
      'last_error': lastError,
      'pending_shifts_count': pendingShiftsCount,
      'pending_gps_points_count': pendingGpsPointsCount,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// Create from database map.
  factory SyncMetadata.fromMap(Map<String, dynamic> map) {
    return SyncMetadata(
      id: map['id'] as String? ?? singletonId,
      lastSyncAttempt: map['last_sync_attempt'] != null
          ? DateTime.parse(map['last_sync_attempt'] as String)
          : null,
      lastSuccessfulSync: map['last_successful_sync'] != null
          ? DateTime.parse(map['last_successful_sync'] as String)
          : null,
      consecutiveFailures: map['consecutive_failures'] as int? ?? 0,
      currentBackoffSeconds: map['current_backoff_seconds'] as int? ?? 0,
      syncInProgress: (map['sync_in_progress'] as int? ?? 0) == 1,
      lastError: map['last_error'] as String?,
      pendingShiftsCount: map['pending_shifts_count'] as int? ?? 0,
      pendingGpsPointsCount: map['pending_gps_points_count'] as int? ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  /// Create default metadata.
  factory SyncMetadata.defaults() {
    final now = DateTime.now().toUtc();
    return SyncMetadata(
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  String toString() {
    return 'SyncMetadata(pending: $totalPending, failures: $consecutiveFailures, '
        'lastSync: $lastSuccessfulSync, error: $lastError)';
  }
}
