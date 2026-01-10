import '../../../shared/services/local_database.dart';
import '../models/sync_log_entry.dart';

/// Service for structured sync logging with configurable levels.
class SyncLogger {
  final LocalDatabase _localDb;

  /// Current minimum log level (logs below this level are ignored).
  SyncLogLevel minLevel;

  /// Whether to also print logs to console.
  final bool printToConsole;

  SyncLogger(
    this._localDb, {
    this.minLevel = SyncLogLevel.info,
    this.printToConsole = true,
  });

  /// Log a debug message.
  Future<void> debug(String message, {Map<String, dynamic>? metadata}) async {
    await _log(SyncLogLevel.debug, message, metadata: metadata);
  }

  /// Log an info message.
  Future<void> info(String message, {Map<String, dynamic>? metadata}) async {
    await _log(SyncLogLevel.info, message, metadata: metadata);
  }

  /// Log a warning message.
  Future<void> warn(String message, {Map<String, dynamic>? metadata}) async {
    await _log(SyncLogLevel.warn, message, metadata: metadata);
  }

  /// Log an error message.
  Future<void> error(String message, {Map<String, dynamic>? metadata}) async {
    await _log(SyncLogLevel.error, message, metadata: metadata);
  }

  /// Log a sync started event.
  Future<void> syncStarted({
    required int pendingShifts,
    required int pendingGpsPoints,
  }) async {
    await info('Sync started', metadata: {
      'event': 'sync_started',
      'pending_shifts': pendingShifts,
      'pending_gps_points': pendingGpsPoints,
      'total_pending': pendingShifts + pendingGpsPoints,
    });
  }

  /// Log a sync completed event.
  Future<void> syncCompleted({
    required int syncedShifts,
    required int syncedGpsPoints,
    required int failedShifts,
    required int failedGpsPoints,
    required Duration duration,
  }) async {
    final level = (failedShifts > 0 || failedGpsPoints > 0)
        ? SyncLogLevel.warn
        : SyncLogLevel.info;

    await _log(level, 'Sync completed', metadata: {
      'event': 'sync_completed',
      'synced_shifts': syncedShifts,
      'synced_gps_points': syncedGpsPoints,
      'failed_shifts': failedShifts,
      'failed_gps_points': failedGpsPoints,
      'duration_ms': duration.inMilliseconds,
    });
  }

  /// Log a sync failed event.
  Future<void> syncFailed({
    required String error,
    required int attemptNumber,
    required Duration nextRetryIn,
  }) async {
    await _log(SyncLogLevel.error, 'Sync failed', metadata: {
      'event': 'sync_failed',
      'error': error,
      'attempt': attemptNumber,
      'next_retry_seconds': nextRetryIn.inSeconds,
    });
  }

  /// Log a batch processed event.
  Future<void> batchProcessed({
    required String type,
    required int batchNumber,
    required int batchSize,
    required int remaining,
    required Duration duration,
  }) async {
    await debug('Batch processed', metadata: {
      'event': 'batch_processed',
      'type': type,
      'batch': batchNumber,
      'size': batchSize,
      'remaining': remaining,
      'duration_ms': duration.inMilliseconds,
    });
  }

  /// Log a record quarantined event.
  Future<void> recordQuarantined({
    required String type,
    required String recordId,
    required String reason,
  }) async {
    await warn('Record quarantined', metadata: {
      'event': 'record_quarantined',
      'type': type,
      'record_id': recordId,
      'reason': reason,
    });
  }

  /// Log a connectivity change event.
  Future<void> connectivityChanged({
    required bool isConnected,
  }) async {
    await info(
      isConnected ? 'Network connected' : 'Network disconnected',
      metadata: {
        'event': 'connectivity_changed',
        'connected': isConnected,
      },
    );
  }

  /// Log a backoff event.
  Future<void> backoffScheduled({
    required int attempt,
    required Duration delay,
  }) async {
    await debug('Backoff scheduled', metadata: {
      'event': 'backoff_scheduled',
      'attempt': attempt,
      'delay_seconds': delay.inSeconds,
    });
  }

  /// Get recent logs.
  Future<List<SyncLogEntry>> getRecentLogs({
    SyncLogLevel? minLevel,
    int limit = 100,
  }) async {
    return await _localDb.getRecentLogs(
      minLevel: minLevel,
      limit: limit,
    );
  }

  /// Export logs as JSON string.
  Future<String> exportLogs({int? limit}) async {
    return await _localDb.exportLogs(limit: limit);
  }

  /// Rotate old logs to prevent unbounded growth.
  Future<int> rotateIfNeeded({int maxEntries = 10000}) async {
    final count = await _localDb.getLogCount();
    if (count > maxEntries) {
      return await _localDb.rotateOldLogs(keepCount: maxEntries);
    }
    return 0;
  }

  /// Clear all logs.
  Future<void> clearLogs() async {
    await _localDb.clearLogs();
  }

  /// Internal log method.
  Future<void> _log(
    SyncLogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  }) async {
    // Check if log level is enabled
    if (level.index < minLevel.index) return;

    final entry = SyncLogEntry.create(
      level: level,
      message: message,
      metadata: metadata,
    );

    // Print to console if enabled
    if (printToConsole) {
      _printLog(entry);
    }

    // Store in database
    try {
      await _localDb.insertSyncLog(entry);
    } catch (e) {
      // Silently fail to avoid log loops
      if (printToConsole) {
        print('[SyncLogger] Failed to store log: $e');
      }
    }
  }

  void _printLog(SyncLogEntry entry) {
    final prefix = switch (entry.level) {
      SyncLogLevel.debug => '\x1B[90m[DEBUG]',
      SyncLogLevel.info => '\x1B[36m[INFO]',
      SyncLogLevel.warn => '\x1B[33m[WARN]',
      SyncLogLevel.error => '\x1B[31m[ERROR]',
    };
    print('$prefix\x1B[0m ${entry.message}');
  }
}
