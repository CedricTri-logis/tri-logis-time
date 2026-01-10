# Sync API Contracts

**Feature**: 005-offline-resilience
**Date**: 2026-01-10
**Version**: 1.0.0

## Overview

This document defines the internal service contracts for the offline resilience sync system. These are Dart service interfaces, not REST APIs. The external Supabase API contracts are documented separately.

---

## 1. SyncService Interface

**File**: `lib/features/shifts/services/sync_service.dart`

### Enhanced Interface

```dart
abstract class ISyncService {
  /// Execute full sync operation with progress tracking
  ///
  /// - Syncs pending shifts first, then GPS points in batches
  /// - Emits progress events during operation
  /// - Returns comprehensive result with success/failure counts
  /// - Implements resumable sync on interruption
  Future<SyncResult> syncAll({
    void Function(SyncProgress)? onProgress,
  });

  /// Sync a single shift to server
  ///
  /// - Handles both clock-in and clock-out scenarios
  /// - Returns server-assigned ID on success
  /// - Throws [SyncException] on failure
  Future<String?> syncShift(LocalShift shift);

  /// Sync batch of GPS points
  ///
  /// - Batch size configurable (default: 100)
  /// - Maps local shift IDs to server IDs
  /// - Skips orphaned points (no server shift ID)
  /// - Returns count of successfully synced points
  Future<int> syncGpsBatch(List<LocalGpsPoint> points);

  /// Clean up old synced data
  ///
  /// - Removes synced GPS points older than threshold
  /// - Respects storage warning thresholds
  /// - Returns count of deleted records
  Future<int> cleanupOldData({
    Duration olderThan = const Duration(days: 30),
  });

  /// Check if sync is currently in progress
  bool get isSyncing;

  /// Stream of sync progress events
  Stream<SyncProgress> get progressStream;

  /// Cancel ongoing sync operation
  ///
  /// - Safely stops current batch
  /// - Preserves already-synced data
  Future<void> cancelSync();
}
```

### SyncResult Model

```dart
class SyncResult {
  final int syncedShifts;
  final int failedShifts;
  final int syncedGpsPoints;
  final int failedGpsPoints;
  final int quarantinedRecords;
  final String? lastError;
  final Duration duration;
  final bool wasInterrupted;

  const SyncResult({
    this.syncedShifts = 0,
    this.failedShifts = 0,
    this.syncedGpsPoints = 0,
    this.failedGpsPoints = 0,
    this.quarantinedRecords = 0,
    this.lastError,
    required this.duration,
    this.wasInterrupted = false,
  });

  bool get hasErrors => failedShifts > 0 || failedGpsPoints > 0;
  bool get isSuccess => !hasErrors && !wasInterrupted;
  int get totalSynced => syncedShifts + syncedGpsPoints;
  int get totalFailed => failedShifts + failedGpsPoints;
}
```

### SyncException

```dart
enum SyncErrorCode {
  networkError,
  serverError,
  authenticationError,
  validationError,
  conflictError,
  quotaExceeded,
  unknown,
}

class SyncException implements Exception {
  final SyncErrorCode code;
  final String message;
  final dynamic originalError;
  final String? recordId;

  const SyncException({
    required this.code,
    required this.message,
    this.originalError,
    this.recordId,
  });

  bool get isRetryable =>
    code == SyncErrorCode.networkError ||
    code == SyncErrorCode.serverError;
}
```

---

## 2. SyncLogger Interface

**File**: `lib/features/shifts/services/sync_logger.dart` (NEW)

### Interface Definition

```dart
abstract class ISyncLogger {
  /// Current logging level
  SyncLogLevel get level;

  /// Set logging level
  set level(SyncLogLevel newLevel);

  /// Log a debug message
  void debug(String message, {Map<String, dynamic>? metadata});

  /// Log an info message
  void info(String message, {Map<String, dynamic>? metadata});

  /// Log a warning message
  void warn(String message, {Map<String, dynamic>? metadata});

  /// Log an error message
  void error(String message, {
    Map<String, dynamic>? metadata,
    Object? exception,
    StackTrace? stackTrace,
  });

  /// Log sync operation start
  void logSyncStart({
    required int pendingShifts,
    required int pendingGpsPoints,
  });

  /// Log sync operation completion
  void logSyncComplete(SyncResult result);

  /// Log batch progress
  void logBatchProgress({
    required int batchNumber,
    required int totalBatches,
    required int itemsInBatch,
  });

  /// Get recent log entries
  Future<List<SyncLogEntry>> getRecentLogs({
    SyncLogLevel? minLevel,
    int limit = 100,
  });

  /// Export logs to external file
  Future<String> exportLogs();

  /// Rotate old log entries
  Future<int> rotateLogs();
}
```

### Log Entry Format

```dart
/// Standard log entry format
class LogFormat {
  /// ISO8601 timestamp in UTC
  static String timestamp(DateTime dt) => dt.toUtc().toIso8601String();

  /// Standard metadata fields
  static const metadataFields = {
    'batch_size': int,
    'batch_number': int,
    'duration_ms': int,
    'error_code': String,
    'shift_id': String,
    'gps_count': int,
    'retry_count': int,
  };
}
```

---

## 3. BackoffStrategy Interface

**File**: `lib/features/shifts/services/sync_service.dart` (embedded)

### Interface Definition

```dart
abstract class IBackoffStrategy {
  /// Calculate delay for given attempt number
  ///
  /// [attempt] Zero-based attempt count
  /// Returns duration to wait before retry
  Duration getDelay(int attempt);

  /// Reset backoff state
  void reset();

  /// Check if max retries exceeded
  bool isExhausted(int attempt);
}

/// Exponential backoff with jitter implementation
class ExponentialBackoff implements IBackoffStrategy {
  static const Duration baseDelay = Duration(seconds: 30);
  static const Duration maxDelay = Duration(minutes: 15);
  static const int maxAttempts = 10;
  static const double jitterFactor = 0.1;

  @override
  Duration getDelay(int attempt) {
    if (attempt >= maxAttempts) return maxDelay;

    final exponentialMs = baseDelay.inMilliseconds * pow(2, attempt);
    final cappedMs = min(exponentialMs, maxDelay.inMilliseconds);
    final jitterMs = (Random().nextDouble() - 0.5) * 2 * jitterFactor * cappedMs;

    return Duration(milliseconds: (cappedMs + jitterMs).round());
  }

  @override
  void reset() {
    // Stateless - no reset needed
  }

  @override
  bool isExhausted(int attempt) => attempt >= maxAttempts;
}
```

---

## 4. StorageMonitor Interface

**File**: `lib/features/shifts/services/storage_monitor.dart` (NEW)

### Interface Definition

```dart
abstract class IStorageMonitor {
  /// Calculate current storage metrics
  Future<StorageMetrics> calculateMetrics();

  /// Get cached storage metrics
  Future<StorageMetrics> getMetrics();

  /// Check if storage warning threshold reached
  Future<bool> isWarningLevel();

  /// Check if storage critical threshold reached
  Future<bool> isCriticalLevel();

  /// Free up storage by pruning old synced data
  ///
  /// [targetFreePercent] Target percentage to free up
  /// Returns bytes freed
  Future<int> freeStorage({int targetFreePercent = 30});

  /// Stream of storage metric updates
  Stream<StorageMetrics> get metricsStream;
}
```

### Storage Warning Events

```dart
enum StorageWarningLevel { none, warning, critical }

class StorageWarningEvent {
  final StorageWarningLevel level;
  final int usedBytes;
  final int totalBytes;
  final double usagePercent;
  final String message;

  const StorageWarningEvent({
    required this.level,
    required this.usedBytes,
    required this.totalBytes,
    required this.usagePercent,
    required this.message,
  });
}
```

---

## 5. QuarantineService Interface

**File**: `lib/features/shifts/services/quarantine_service.dart` (NEW)

### Interface Definition

```dart
abstract class IQuarantineService {
  /// Quarantine a failed shift record
  Future<void> quarantineShift(
    LocalShift shift, {
    required String errorCode,
    required String errorMessage,
  });

  /// Quarantine a failed GPS point
  Future<void> quarantineGpsPoint(
    LocalGpsPoint point, {
    required String errorCode,
    required String errorMessage,
  });

  /// Get all pending quarantined records
  Future<List<QuarantinedRecord>> getPendingRecords({
    RecordType? type,
    int limit = 50,
  });

  /// Retry a quarantined record
  ///
  /// Attempts to sync the record again
  /// Returns true if successful (and removes from quarantine)
  Future<bool> retryRecord(String id);

  /// Mark record as resolved
  Future<void> resolveRecord(String id, {required String notes});

  /// Mark record as discarded
  Future<void> discardRecord(String id, {required String reason});

  /// Get quarantine statistics
  Future<QuarantineStats> getStats();
}

class QuarantineStats {
  final int pendingShifts;
  final int pendingGpsPoints;
  final int resolvedCount;
  final int discardedCount;
  final DateTime? oldestPending;

  const QuarantineStats({
    this.pendingShifts = 0,
    this.pendingGpsPoints = 0,
    this.resolvedCount = 0,
    this.discardedCount = 0,
    this.oldestPending,
  });

  int get totalPending => pendingShifts + pendingGpsPoints;
  bool get hasPending => totalPending > 0;
}
```

---

## 6. SyncProvider State Contract

**File**: `lib/features/shifts/providers/sync_provider.dart`

### Enhanced State

```dart
@freezed
class SyncState with _$SyncState {
  const factory SyncState({
    @Default(SyncStatus.synced) SyncStatus status,
    @Default(0) int pendingShifts,
    @Default(0) int pendingGpsPoints,
    String? lastError,
    DateTime? lastSyncTime,
    SyncProgress? progress,
    @Default(0) int consecutiveFailures,
    Duration? nextRetryIn,
    @Default(false) bool isConnected,
  }) = _SyncState;

  const SyncState._();

  bool get hasPendingData => pendingShifts > 0 || pendingGpsPoints > 0;
  int get totalPending => pendingShifts + pendingGpsPoints;
  bool get isRetrying => consecutiveFailures > 0;
  bool get canSync => isConnected && hasPendingData && status != SyncStatus.syncing;
}
```

### Provider Actions

```dart
abstract class ISyncNotifier {
  /// Trigger sync operation
  Future<void> syncPendingData();

  /// Retry failed sync
  Future<void> retrySync();

  /// Clear current error
  void clearError();

  /// Notify of new pending data
  void notifyPendingData();

  /// Cancel ongoing sync
  Future<void> cancelSync();

  /// Force update pending counts
  Future<void> refreshPendingCounts();
}
```

---

## 7. Error Handling Contract

### Retry Decision Matrix

```dart
/// Determines whether and when to retry sync operation
class RetryDecision {
  final bool shouldRetry;
  final Duration? retryAfter;
  final bool shouldQuarantine;
  final String reason;

  const RetryDecision({
    required this.shouldRetry,
    this.retryAfter,
    this.shouldQuarantine = false,
    required this.reason,
  });

  static RetryDecision fromError(SyncException error, int attemptCount) {
    switch (error.code) {
      case SyncErrorCode.networkError:
        return RetryDecision(
          shouldRetry: true,
          retryAfter: ExponentialBackoff().getDelay(attemptCount),
          reason: 'Network unavailable, will retry',
        );

      case SyncErrorCode.serverError:
        return RetryDecision(
          shouldRetry: attemptCount < 5,
          retryAfter: ExponentialBackoff().getDelay(attemptCount),
          reason: 'Server error, will retry',
        );

      case SyncErrorCode.validationError:
        return RetryDecision(
          shouldRetry: false,
          shouldQuarantine: true,
          reason: 'Invalid data, quarantined for review',
        );

      case SyncErrorCode.authenticationError:
        return RetryDecision(
          shouldRetry: false,
          reason: 'Authentication required',
        );

      case SyncErrorCode.conflictError:
        return RetryDecision(
          shouldRetry: true,
          retryAfter: Duration.zero,  // Retry immediately with conflict resolution
          reason: 'Conflict detected, resolving',
        );

      default:
        return RetryDecision(
          shouldRetry: attemptCount < 3,
          retryAfter: ExponentialBackoff().getDelay(attemptCount),
          reason: 'Unknown error, will retry',
        );
    }
  }
}
```

---

## 8. Supabase RPC Contracts

### Existing Endpoints (No Changes Required)

```dart
/// Clock in shift
/// RPC: clock_in
Future<Map<String, dynamic>> clockIn({
  required String requestId,
  required String employeeId,
  required DateTime clockedInAt,
  double? latitude,
  double? longitude,
  double? accuracy,
});

/// Clock out shift
/// RPC: clock_out
Future<Map<String, dynamic>> clockOut({
  required String shiftId,
  required DateTime clockedOutAt,
  double? latitude,
  double? longitude,
  double? accuracy,
});

/// Sync GPS points batch
/// RPC: sync_gps_points
Future<void> syncGpsPoints({
  required List<Map<String, dynamic>> points,
});
```

### Request/Response Schemas

```dart
/// GPS Point Sync Request Item
class GpsPointSyncRequest {
  final String clientId;      // UUID v4 (idempotency key)
  final String shiftId;       // Server shift ID
  final String employeeId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;
  final String? deviceId;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'shift_id': shiftId,
    'employee_id': employeeId,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    'device_id': deviceId,
  };
}
```

---

## Usage Examples

### Sync with Progress Tracking

```dart
final syncService = ref.read(syncServiceProvider);

await syncService.syncAll(
  onProgress: (progress) {
    print('Synced ${progress.syncedItems}/${progress.totalItems}');
    print('Current: ${progress.currentOperation}');
  },
);
```

### Logging Sync Operations

```dart
final logger = ref.read(syncLoggerProvider);

logger.logSyncStart(
  pendingShifts: 2,
  pendingGpsPoints: 150,
);

// ... perform sync ...

logger.logSyncComplete(result);
```

### Storage Monitoring

```dart
final monitor = ref.read(storageMonitorProvider);

if (await monitor.isCriticalLevel()) {
  final freed = await monitor.freeStorage(targetFreePercent: 30);
  logger.info('Freed ${freed} bytes of storage');
}
```
