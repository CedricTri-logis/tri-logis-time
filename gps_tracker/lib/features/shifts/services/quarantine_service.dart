import 'package:uuid/uuid.dart';

import '../../../shared/services/local_database.dart';
import '../models/local_gps_point.dart';
import '../models/local_shift.dart';
import '../models/quarantined_record.dart';
import 'sync_logger.dart';

/// Service for managing quarantined records that failed sync.
class QuarantineService {
  final LocalDatabase _localDb;
  final SyncLogger _logger;
  final Uuid _uuid;

  QuarantineService(this._localDb, this._logger) : _uuid = const Uuid();

  /// Quarantine a shift that failed to sync.
  Future<QuarantinedRecord> quarantineShift({
    required LocalShift shift,
    required String errorCode,
    required String errorMessage,
  }) async {
    final record = QuarantinedRecord(
      id: _uuid.v4(),
      recordType: RecordType.shift,
      originalId: shift.id,
      recordData: shift.toMap(),
      errorCode: errorCode,
      errorMessage: errorMessage,
      quarantinedAt: DateTime.now().toUtc(),
      createdAt: DateTime.now().toUtc(),
    );

    await _localDb.insertQuarantinedRecord(record);

    await _logger.recordQuarantined(
      type: 'shift',
      recordId: shift.id,
      reason: '$errorCode: $errorMessage',
    );

    return record;
  }

  /// Quarantine a GPS point that failed to sync.
  Future<QuarantinedRecord> quarantineGpsPoint({
    required LocalGpsPoint point,
    required String errorCode,
    required String errorMessage,
  }) async {
    final record = QuarantinedRecord(
      id: _uuid.v4(),
      recordType: RecordType.gpsPoint,
      originalId: point.id,
      recordData: point.toMap(),
      errorCode: errorCode,
      errorMessage: errorMessage,
      quarantinedAt: DateTime.now().toUtc(),
      createdAt: DateTime.now().toUtc(),
    );

    await _localDb.insertQuarantinedRecord(record);

    await _logger.recordQuarantined(
      type: 'gps_point',
      recordId: point.id,
      reason: '$errorCode: $errorMessage',
    );

    return record;
  }

  /// Get all pending quarantined records.
  Future<List<QuarantinedRecord>> getPendingRecords({
    RecordType? type,
    int limit = 50,
  }) async {
    return await _localDb.getPendingQuarantined(type: type, limit: limit);
  }

  /// Get quarantine statistics.
  Future<QuarantineStats> getStats() async {
    final byType = await _localDb.getQuarantineStats();
    return QuarantineStats(
      pendingShifts: byType[RecordType.shift] ?? 0,
      pendingGpsPoints: byType[RecordType.gpsPoint] ?? 0,
    );
  }

  /// Resolve a quarantined record (marks as successfully handled).
  Future<void> resolveRecord(String id, {required String notes}) async {
    await _localDb.resolveQuarantined(id, notes);

    await _logger.info(
      'Quarantined record resolved',
      metadata: {'id': id, 'notes': notes},
    );
  }

  /// Discard a quarantined record (marks as intentionally discarded).
  Future<void> discardRecord(String id, {required String reason}) async {
    await _localDb.discardQuarantined(id, reason);

    await _logger.info(
      'Quarantined record discarded',
      metadata: {'id': id, 'reason': reason},
    );
  }

  /// Attempt to retry a quarantined shift.
  Future<bool> retryShift(QuarantinedRecord record) async {
    if (record.recordType != RecordType.shift) {
      throw ArgumentError('Record is not a shift');
    }

    try {
      final shift = LocalShift.fromMap(record.recordData);

      // Reset sync status to pending
      await _localDb.insertShift(shift.copyWith(
        syncStatus: 'pending',
        syncError: null,
      ));

      // Mark quarantine as resolved
      await resolveRecord(record.id, notes: 'Re-queued for sync');

      return true;
    } catch (e) {
      await _logger.error(
        'Failed to retry quarantined shift',
        metadata: {'id': record.id, 'error': e.toString()},
      );
      return false;
    }
  }

  /// Attempt to retry a quarantined GPS point.
  Future<bool> retryGpsPoint(QuarantinedRecord record) async {
    if (record.recordType != RecordType.gpsPoint) {
      throw ArgumentError('Record is not a GPS point');
    }

    try {
      final point = LocalGpsPoint.fromMap(record.recordData);

      // Re-insert with pending status
      await _localDb.insertGpsPoint(point.copyWith(syncStatus: 'pending'));

      // Mark quarantine as resolved
      await resolveRecord(record.id, notes: 'Re-queued for sync');

      return true;
    } catch (e) {
      await _logger.error(
        'Failed to retry quarantined GPS point',
        metadata: {'id': record.id, 'error': e.toString()},
      );
      return false;
    }
  }

  /// Retry all pending quarantined records.
  Future<RetryResult> retryAll() async {
    final records = await getPendingRecords();

    int retried = 0;
    int failed = 0;

    for (final record in records) {
      bool success;
      if (record.recordType == RecordType.shift) {
        success = await retryShift(record);
      } else {
        success = await retryGpsPoint(record);
      }

      if (success) {
        retried++;
      } else {
        failed++;
      }
    }

    await _logger.info(
      'Quarantine retry complete',
      metadata: {'retried': retried, 'failed': failed},
    );

    return RetryResult(retried: retried, failed: failed);
  }

  /// Discard all pending quarantined records of a specific type.
  Future<int> discardAllOfType(RecordType type, {required String reason}) async {
    final records = await getPendingRecords(type: type);

    for (final record in records) {
      await discardRecord(record.id, reason: reason);
    }

    return records.length;
  }

  /// Check if there are any quarantined records.
  Future<bool> hasQuarantinedRecords() async {
    final records = await getPendingRecords(limit: 1);
    return records.isNotEmpty;
  }
}

/// Statistics about quarantined records.
class QuarantineStats {
  final int pendingShifts;
  final int pendingGpsPoints;

  QuarantineStats({
    required this.pendingShifts,
    required this.pendingGpsPoints,
  });

  int get total => pendingShifts + pendingGpsPoints;
  bool get hasAny => total > 0;

  @override
  String toString() =>
      'QuarantineStats(shifts: $pendingShifts, gps: $pendingGpsPoints)';
}

/// Result of a retry operation.
class RetryResult {
  final int retried;
  final int failed;

  RetryResult({required this.retried, required this.failed});

  int get total => retried + failed;
  bool get allSucceeded => failed == 0;
  double get successRate => total > 0 ? (retried / total) * 100 : 0;

  @override
  String toString() => 'RetryResult(retried: $retried, failed: $failed)';
}
