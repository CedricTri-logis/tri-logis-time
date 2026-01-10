/// Model for tracking real-time sync progress.
/// This is a transient model - not persisted to database.
class SyncProgress {
  final int syncedShifts;
  final int totalShifts;
  final int syncedGpsPoints;
  final int totalGpsPoints;
  final DateTime startedAt;
  final String? currentOperation;

  const SyncProgress({
    this.syncedShifts = 0,
    this.totalShifts = 0,
    this.syncedGpsPoints = 0,
    this.totalGpsPoints = 0,
    required this.startedAt,
    this.currentOperation,
  });

  /// Get total items to sync.
  int get totalItems => totalShifts + totalGpsPoints;

  /// Get total items synced so far.
  int get syncedItems => syncedShifts + syncedGpsPoints;

  /// Get remaining items to sync.
  int get remainingItems => totalItems - syncedItems;

  /// Get sync progress percentage (0-100).
  double get percentage =>
      totalItems > 0 ? (syncedItems / totalItems) * 100 : 0;

  /// Check if sync is complete.
  bool get isComplete => syncedItems >= totalItems;

  /// Get elapsed time since sync started.
  Duration get elapsed => DateTime.now().difference(startedAt);

  /// Estimate remaining time based on current progress.
  Duration? get estimatedRemaining {
    if (syncedItems == 0 || isComplete) return null;
    final msPerItem = elapsed.inMilliseconds / syncedItems;
    final remainingMs = (msPerItem * remainingItems).round();
    return Duration(milliseconds: remainingMs);
  }

  /// Create a copy with modified fields.
  SyncProgress copyWith({
    int? syncedShifts,
    int? totalShifts,
    int? syncedGpsPoints,
    int? totalGpsPoints,
    DateTime? startedAt,
    String? currentOperation,
  }) {
    return SyncProgress(
      syncedShifts: syncedShifts ?? this.syncedShifts,
      totalShifts: totalShifts ?? this.totalShifts,
      syncedGpsPoints: syncedGpsPoints ?? this.syncedGpsPoints,
      totalGpsPoints: totalGpsPoints ?? this.totalGpsPoints,
      startedAt: startedAt ?? this.startedAt,
      currentOperation: currentOperation ?? this.currentOperation,
    );
  }

  /// Create initial progress state.
  factory SyncProgress.initial({
    required int totalShifts,
    required int totalGpsPoints,
  }) {
    return SyncProgress(
      totalShifts: totalShifts,
      totalGpsPoints: totalGpsPoints,
      startedAt: DateTime.now(),
      currentOperation: 'Starting sync...',
    );
  }

  @override
  String toString() {
    return 'SyncProgress($syncedItems/$totalItems, ${percentage.toStringAsFixed(1)}%, '
        'operation: $currentOperation)';
  }
}
