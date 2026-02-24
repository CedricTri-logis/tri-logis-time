import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../../shared/services/local_database.dart';
import '../models/sync_progress.dart';
import 'diagnostic_sync_service.dart';
import 'quarantine_service.dart';
import 'shift_service.dart';

/// Result of a sync operation.
class SyncResult {
  final int syncedShifts;
  final int failedShifts;
  final int syncedGpsPoints;
  final int failedGpsPoints;
  final String? lastError;

  SyncResult({
    this.syncedShifts = 0,
    this.failedShifts = 0,
    this.syncedGpsPoints = 0,
    this.failedGpsPoints = 0,
    this.lastError,
  });

  bool get hasErrors => failedShifts > 0 || failedGpsPoints > 0;
  bool get isEmpty =>
      syncedShifts == 0 &&
      failedShifts == 0 &&
      syncedGpsPoints == 0 &&
      failedGpsPoints == 0;
}

/// Service for synchronizing local data to Supabase.
class SyncService {
  final SupabaseClient _supabase;
  final LocalDatabase _localDb;
  final ShiftService _shiftService;
  QuarantineService? _quarantineService;
  DiagnosticSyncService? _diagnosticSyncService;

  static const int _gpsPointBatchSize = 100;

  /// Max sync attempts for orphaned GPS points before quarantine.
  static const int _maxOrphanSyncAttempts = 3;

  /// Track per-shift orphan sync attempts (shift_id -> attempt count).
  final Map<String, int> _orphanAttempts = {};

  /// Stream controller for progress updates.
  final _progressController = StreamController<SyncProgress>.broadcast();

  DiagnosticLogger? get _logger => DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  SyncService(this._supabase, this._localDb, this._shiftService);

  /// Set the quarantine service (injected to avoid circular dependencies).
  void setQuarantineService(QuarantineService service) {
    _quarantineService = service;
  }

  /// Set the diagnostic sync service (injected to avoid circular dependencies).
  void setDiagnosticSyncService(DiagnosticSyncService service) {
    _diagnosticSyncService = service;
  }

  /// Stream of sync progress updates.
  Stream<SyncProgress> get progressStream => _progressController.stream;

  /// Get the current user ID.
  String? get _currentUserId => _supabase.auth.currentUser?.id;

  /// Sync all pending data with progress tracking.
  Future<SyncResult> syncAll() async {
    final userId = _currentUserId;
    if (userId == null) {
      return SyncResult(lastError: 'Not authenticated');
    }

    // Get counts for progress tracking
    final pendingShifts = await _localDb.getPendingShifts(userId);
    final errorShifts = await _localDb.getErrorShifts(userId);
    final totalPendingGps = await _localDb.getPendingGpsPointCount();

    final allShifts = [...pendingShifts, ...errorShifts];
    final totalShifts = allShifts.length;

    // Initialize progress
    var progress = SyncProgress.initial(
      totalShifts: totalShifts,
      totalGpsPoints: totalPendingGps,
    );
    _progressController.add(progress);

    int syncedShifts = 0;
    int failedShifts = 0;
    int syncedGpsPoints = 0;
    int failedGpsPoints = 0;
    String? lastError;

    // Sync shifts with progress
    for (int i = 0; i < allShifts.length; i++) {
      final shift = allShifts[i];

      progress = progress.copyWith(
        currentOperation: 'Syncing shift ${i + 1} of $totalShifts',
      );
      _progressController.add(progress);

      final success = await _shiftService.syncShift(shift.id);
      if (success) {
        syncedShifts++;
      } else {
        failedShifts++;
        lastError = 'Failed to sync shift ${shift.id}';
      }

      progress = progress.copyWith(syncedShifts: syncedShifts + failedShifts);
      _progressController.add(progress);
    }

    // Sync GPS gaps
    await _syncGpsGaps();

    // Sync pending GPS points with progress
    final gpsResult = await _syncGpsPointsWithProgress(
      totalPending: totalPendingGps,
      onProgress: (synced, operation) {
        progress = progress.copyWith(
          syncedGpsPoints: synced,
          currentOperation: operation,
        );
        _progressController.add(progress);
      },
    );

    syncedGpsPoints = gpsResult.syncedGpsPoints;
    failedGpsPoints = gpsResult.failedGpsPoints;
    if (gpsResult.lastError != null) {
      lastError = gpsResult.lastError;
    }

    // Trigger trip re-detection for completed shifts that had GPS points synced
    if (syncedGpsPoints > 0) {
      _triggerTripDetectionForCompletedShifts(userId);
    }

    // Sync diagnostic events (lowest priority — never blocks GPS/shift sync)
    try {
      await _diagnosticSyncService?.syncDiagnosticEvents();
    } catch (_) {
      // Never let diagnostic sync failures affect the main sync result
    }

    // Final progress update
    progress = progress.copyWith(
      syncedGpsPoints: syncedGpsPoints,
      currentOperation: 'Sync complete',
    );
    _progressController.add(progress);

    return SyncResult(
      syncedShifts: syncedShifts,
      failedShifts: failedShifts,
      syncedGpsPoints: syncedGpsPoints,
      failedGpsPoints: failedGpsPoints,
      lastError: lastError,
    );
  }

  /// Sync pending GPS points in batches with progress callback.
  Future<SyncResult> _syncGpsPointsWithProgress({
    required int totalPending,
    required void Function(int synced, String operation) onProgress,
  }) async {
    int syncedCount = 0;
    int failedCount = 0;
    int batchNumber = 0;
    String? lastError;

    while (true) {
      final pendingPoints = await _localDb.getPendingGpsPoints(
        limit: _gpsPointBatchSize,
      );

      if (pendingPoints.isEmpty) break;

      batchNumber++;
      final remainingBatches =
          ((totalPending - syncedCount) / _gpsPointBatchSize).ceil();

      onProgress(
        syncedCount,
        'Syncing GPS batch $batchNumber (${pendingPoints.length} points, $remainingBatches remaining)',
      );

      // Map local shift IDs to server IDs, skipping points without valid server IDs
      final mappedPoints = <Map<String, dynamic>>[];
      final validPointIds = <String>[];
      // Track point ID → local point for potential quarantine
      final pointsByClientId = <String, dynamic>{};

      int skippedOrphanCount = 0;

      for (final point in pendingPoints) {
        var shift = await _localDb.getShiftById(point.shiftId);

        // If shift has no server ID, attempt inline shift sync
        if (shift != null && shift.serverId == null) {
          final synced = await _shiftService.syncShift(shift.id);
          if (synced) {
            // Re-fetch to get the new serverId
            shift = await _localDb.getShiftById(point.shiftId);
          }
        }

        if (shift != null && shift.serverId != null) {
          final pointJson = point.toJson();
          pointJson['shift_id'] = shift.serverId; // Use server ID
          mappedPoints.add(pointJson);
          validPointIds.add(point.id);
          pointsByClientId[point.id] = point;
        } else {
          // Track orphan attempts per shift and quarantine after threshold
          skippedOrphanCount++;
          final attempts = (_orphanAttempts[point.shiftId] ?? 0) + 1;
          _orphanAttempts[point.shiftId] = attempts;

          if (attempts >= _maxOrphanSyncAttempts && _quarantineService != null) {
            try {
              await _quarantineService!.quarantineGpsPoint(
                point: point,
                errorCode: 'orphaned_shift',
                errorMessage: 'Shift ${point.shiftId} has no server ID after $attempts sync attempts',
              );
              // Mark as synced to remove from pending queue
              await _localDb.markGpsPointsSynced([point.id]);
              _logger?.sync(Severity.warn, 'GPS point quarantined', metadata: {'point_id': point.id, 'shift_id': point.shiftId, 'reason': 'orphaned_shift', 'attempt_count': attempts});
            } catch (_) {
              failedCount++;
            }
          } else {
            failedCount++;
          }
        }
      }

      // If all points were orphaned (no valid server IDs), report as error to trigger retry
      if (mappedPoints.isEmpty) {
        if (skippedOrphanCount > 0) {
          lastError = '$skippedOrphanCount GPS points orphaned (shift not synced)';
        }
        break;
      }

      try {
        final result = await _supabase.rpc<Map<String, dynamic>>(
          'sync_gps_points',
          params: {
            'p_points': mappedPoints,
          },
        );
        if (result['status'] == 'success') {
          final inserted = result['inserted'] as int? ?? 0;
          final duplicates = result['duplicates'] as int? ?? 0;
          final serverErrors = result['errors'] as int? ?? 0;
          final failedIds = (result['failed_ids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toSet() ?? <String>{};

          syncedCount += inserted + duplicates;

          // Mark only non-failed points as synced
          if (failedIds.isEmpty) {
            await _localDb.markGpsPointsSynced(validPointIds);
          } else {
            final succeededIds = validPointIds
                .where((id) => !failedIds.contains(id))
                .toList();
            await _localDb.markGpsPointsSynced(succeededIds);
            failedCount += serverErrors;
            lastError = '$serverErrors GPS points rejected by server';
          }
        } else {
          failedCount += validPointIds.length;
          lastError = result['message'] as String?;
        }
      } catch (e) {
        failedCount += validPointIds.length;
        lastError = e.toString();
        break; // Stop on network error
      }
    }

    return SyncResult(
      syncedGpsPoints: syncedCount,
      failedGpsPoints: failedCount,
      lastError: lastError,
    );
  }

  /// Sync pending GPS gaps to Supabase.
  Future<void> _syncGpsGaps() async {
    final pendingGaps = await _localDb.getPendingGpsGaps();
    if (pendingGaps.isEmpty) return;

    // Map local shift IDs to server IDs
    final mappedGaps = <Map<String, dynamic>>[];
    final validGapIds = <String>[];

    for (final gap in pendingGaps) {
      final shift = await _localDb.getShiftById(gap.shiftId);
      if (shift != null && shift.serverId != null) {
        final gapJson = gap.toJson();
        gapJson['shift_id'] = shift.serverId;
        gapJson['employee_id'] = gap.employeeId;
        mappedGaps.add(gapJson);
        validGapIds.add(gap.id);
      }
    }

    if (mappedGaps.isEmpty) return;

    try {
      final result = await _supabase.rpc<Map<String, dynamic>>(
        'sync_gps_gaps',
        params: {'p_gaps': mappedGaps},
      );
      if (result['status'] == 'success') {
        await _localDb.markGpsGapsSynced(validGapIds);
      } else {
        _logger?.sync(Severity.warn, 'GPS gaps sync returned non-success', metadata: {'status': result['status'], 'message': result['message']});
      }
    } catch (e) {
      _logger?.sync(Severity.error, 'GPS gaps sync failed', metadata: {'error': e.toString()});
    }
  }

  /// Sync a single shift.
  Future<bool> syncShift(String shiftId) async {
    return await _shiftService.syncShift(shiftId);
  }

  /// Check if there's pending data to sync.
  Future<bool> hasPendingData() async {
    final userId = _currentUserId;
    if (userId == null) return false;

    final pendingShifts = await _localDb.getPendingShifts(userId);
    if (pendingShifts.isNotEmpty) return true;

    final errorShifts = await _localDb.getErrorShifts(userId);
    if (errorShifts.isNotEmpty) return true;

    final pendingPoints = await _localDb.getPendingGpsPoints(limit: 1);
    return pendingPoints.isNotEmpty;
  }

  /// Get count of pending items.
  Future<({int shifts, int gpsPoints})> getPendingCounts() async {
    final userId = _currentUserId;
    if (userId == null) return (shifts: 0, gpsPoints: 0);

    final pendingShifts = await _localDb.getPendingShifts(userId);
    final errorShifts = await _localDb.getErrorShifts(userId);
    final pendingGpsCount = await _localDb.getPendingGpsPointCount();

    return (
      shifts: pendingShifts.length + errorShifts.length,
      gpsPoints: pendingGpsCount,
    );
  }

  /// Clean up old synced data.
  Future<int> cleanupOldData() async {
    final threshold = DateTime.now().subtract(const Duration(days: 30));
    return await _localDb.deleteOldSyncedGpsPoints(threshold);
  }

  /// Fire-and-forget trip detection for recently completed shifts.
  /// Called after GPS points sync to re-detect trips with new data.
  void _triggerTripDetectionForCompletedShifts(String userId) async {
    try {
      // Get recently completed shifts (last 24h) to re-detect trips
      final recentShifts = await _localDb.getShiftHistory(
        employeeId: userId,
        limit: 10,
        offset: 0,
      );

      for (final shift in recentShifts) {
        if (shift.status == 'completed' && shift.serverId != null) {
          _supabase.rpc('detect_trips', params: {
            'p_shift_id': shift.serverId,
          }).then((_) {
            _logger?.sync(Severity.debug, 'Trip re-detection completed', metadata: {'shift_id': shift.serverId});
          }).catchError((e) {
            _logger?.sync(Severity.warn, 'Trip re-detection failed', metadata: {'shift_id': shift.serverId, 'error': e.toString()});
          });
        }
      }
    } catch (e) {
      _logger?.sync(Severity.error, 'Failed to trigger trip re-detection', metadata: {'error': e.toString()});
    }
  }

  /// Dispose resources.
  void dispose() {
    _progressController.close();
  }
}
