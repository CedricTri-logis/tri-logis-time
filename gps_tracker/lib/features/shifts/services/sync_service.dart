import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/services/local_database.dart';
import '../models/sync_progress.dart';
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

  static const int _gpsPointBatchSize = 100;

  /// Stream controller for progress updates.
  final _progressController = StreamController<SyncProgress>.broadcast();

  SyncService(this._supabase, this._localDb, this._shiftService);

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

      for (final point in pendingPoints) {
        final shift = await _localDb.getShiftById(point.shiftId);

        // Only sync if shift exists AND has a server ID
        if (shift != null && shift.serverId != null) {
          final pointJson = point.toJson();
          pointJson['shift_id'] = shift.serverId; // Use server ID
          mappedPoints.add(pointJson);
          validPointIds.add(point.id);
        }
        // Points without valid server shift ID are skipped and will be retried later
      }

      // If all points were skipped (no valid server IDs), break to avoid infinite loop
      if (mappedPoints.isEmpty) {
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
          syncedCount += inserted;

          // Mark only successfully synced points as synced
          await _localDb.markGpsPointsSynced(validPointIds);
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

  /// Dispose resources.
  void dispose() {
    _progressController.close();
  }
}
