import 'dart:async';

import '../../../shared/services/local_database.dart';
import '../models/storage_metrics.dart';

/// Service for monitoring local storage usage and triggering cleanup.
class StorageMonitor {
  final LocalDatabase _localDb;

  /// How often to check storage (1 hour as per spec).
  static const Duration checkInterval = Duration(hours: 1);

  /// Data retention period for synced records (30 days as per spec).
  static const Duration retentionPeriod = Duration(days: 30);

  /// Timer for periodic checks.
  Timer? _checkTimer;

  /// Callbacks for storage events.
  void Function(StorageMetrics metrics)? onMetricsUpdated;
  void Function(StorageMetrics metrics)? onWarningThreshold;
  void Function(StorageMetrics metrics)? onCriticalThreshold;

  StorageMonitor(this._localDb);

  /// Start periodic storage monitoring.
  void startMonitoring() {
    // Check immediately
    checkStorage();

    // Then check periodically
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(checkInterval, (_) => checkStorage());
  }

  /// Stop periodic monitoring.
  void stopMonitoring() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  /// Check storage and trigger callbacks if thresholds exceeded.
  Future<StorageMetrics> checkStorage() async {
    final metrics = await _localDb.calculateStorageMetrics();

    onMetricsUpdated?.call(metrics);

    if (metrics.isCritical) {
      onCriticalThreshold?.call(metrics);
      // Auto-cleanup when critical
      await performCleanup();
    } else if (metrics.isWarning) {
      onWarningThreshold?.call(metrics);
    }

    return metrics;
  }

  /// Get current storage metrics (cached if recent).
  Future<StorageMetrics> getMetrics() async {
    final metrics = await _localDb.getStorageMetrics();

    // Recalculate if stale
    if (metrics.isStale) {
      return await _localDb.calculateStorageMetrics();
    }

    return metrics;
  }

  /// Perform storage cleanup.
  /// Removes synced records older than retention period.
  Future<CleanupResult> performCleanup() async {
    final threshold = DateTime.now().subtract(retentionPeriod);

    // Delete old synced GPS points
    final deletedGpsPoints = await _localDb.deleteOldSyncedGpsPoints(threshold);

    // Rotate old logs
    final deletedLogs = await _localDb.rotateOldLogs();

    // Recalculate metrics after cleanup
    final newMetrics = await _localDb.calculateStorageMetrics();

    return CleanupResult(
      deletedGpsPoints: deletedGpsPoints,
      deletedLogs: deletedLogs,
      newMetrics: newMetrics,
    );
  }

  /// Force recalculation of storage metrics.
  Future<StorageMetrics> recalculate() async {
    return await _localDb.calculateStorageMetrics();
  }

  /// Check if cleanup is needed.
  Future<bool> needsCleanup() async {
    final metrics = await getMetrics();
    return metrics.isWarning;
  }

  /// Get storage usage breakdown.
  Future<StorageBreakdown> getBreakdown() async {
    final metrics = await getMetrics();

    return StorageBreakdown(
      shiftsBytes: metrics.shiftsBytes,
      shiftsPercent: metrics.usedBytes > 0
          ? (metrics.shiftsBytes / metrics.usedBytes) * 100
          : 0,
      gpsPointsBytes: metrics.gpsPointsBytes,
      gpsPointsPercent: metrics.usedBytes > 0
          ? (metrics.gpsPointsBytes / metrics.usedBytes) * 100
          : 0,
      logsBytes: metrics.logsBytes,
      logsPercent: metrics.usedBytes > 0
          ? (metrics.logsBytes / metrics.usedBytes) * 100
          : 0,
      totalUsedBytes: metrics.usedBytes,
      totalCapacityBytes: metrics.totalCapacityBytes,
      usagePercent: metrics.usagePercent,
    );
  }

  /// Dispose resources.
  void dispose() {
    stopMonitoring();
  }
}

/// Result of a cleanup operation.
class CleanupResult {
  final int deletedGpsPoints;
  final int deletedLogs;
  final StorageMetrics newMetrics;

  CleanupResult({
    required this.deletedGpsPoints,
    required this.deletedLogs,
    required this.newMetrics,
  });

  int get totalDeleted => deletedGpsPoints + deletedLogs;

  bool get hadEffect => totalDeleted > 0;

  @override
  String toString() =>
      'CleanupResult(gps: $deletedGpsPoints, logs: $deletedLogs, '
      'new usage: ${newMetrics.usagePercent.toStringAsFixed(1)}%)';
}

/// Storage usage breakdown by category.
class StorageBreakdown {
  final int shiftsBytes;
  final double shiftsPercent;
  final int gpsPointsBytes;
  final double gpsPointsPercent;
  final int logsBytes;
  final double logsPercent;
  final int totalUsedBytes;
  final int totalCapacityBytes;
  final double usagePercent;

  StorageBreakdown({
    required this.shiftsBytes,
    required this.shiftsPercent,
    required this.gpsPointsBytes,
    required this.gpsPointsPercent,
    required this.logsBytes,
    required this.logsPercent,
    required this.totalUsedBytes,
    required this.totalCapacityBytes,
    required this.usagePercent,
  });

  int get availableBytes => totalCapacityBytes - totalUsedBytes;

  String get formattedShifts => StorageMetrics.formatBytes(shiftsBytes);
  String get formattedGpsPoints => StorageMetrics.formatBytes(gpsPointsBytes);
  String get formattedLogs => StorageMetrics.formatBytes(logsBytes);
  String get formattedUsed => StorageMetrics.formatBytes(totalUsedBytes);
  String get formattedTotal => StorageMetrics.formatBytes(totalCapacityBytes);
  String get formattedAvailable => StorageMetrics.formatBytes(availableBytes);

  @override
  String toString() =>
      'StorageBreakdown(shifts: $formattedShifts, gps: $formattedGpsPoints, '
      'logs: $formattedLogs, used: $formattedUsed / $formattedTotal)';
}
