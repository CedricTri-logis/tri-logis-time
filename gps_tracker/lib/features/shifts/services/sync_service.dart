import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/services/local_database.dart';
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

  SyncService(this._supabase, this._localDb, this._shiftService);

  /// Get the current user ID.
  String? get _currentUserId => _supabase.auth.currentUser?.id;

  /// Sync all pending data.
  Future<SyncResult> syncAll() async {
    final userId = _currentUserId;
    if (userId == null) {
      return SyncResult(lastError: 'Not authenticated');
    }

    int syncedShifts = 0;
    int failedShifts = 0;
    int syncedGpsPoints = 0;
    int failedGpsPoints = 0;
    String? lastError;

    // Sync pending shifts
    final pendingShifts = await _localDb.getPendingShifts(userId);
    for (final shift in pendingShifts) {
      final success = await _shiftService.syncShift(shift.id);
      if (success) {
        syncedShifts++;
      } else {
        failedShifts++;
        lastError = 'Failed to sync shift ${shift.id}';
      }
    }

    // Also retry error shifts
    final errorShifts = await _localDb.getErrorShifts(userId);
    for (final shift in errorShifts) {
      final success = await _shiftService.syncShift(shift.id);
      if (success) {
        syncedShifts++;
      } else {
        failedShifts++;
        lastError = 'Failed to sync shift ${shift.id}';
      }
    }

    // Sync pending GPS points
    final gpsResult = await _syncGpsPoints();
    syncedGpsPoints = gpsResult.syncedGpsPoints;
    failedGpsPoints = gpsResult.failedGpsPoints;
    if (gpsResult.lastError != null) {
      lastError = gpsResult.lastError;
    }

    return SyncResult(
      syncedShifts: syncedShifts,
      failedShifts: failedShifts,
      syncedGpsPoints: syncedGpsPoints,
      failedGpsPoints: failedGpsPoints,
      lastError: lastError,
    );
  }

  /// Sync pending GPS points in batches.
  Future<SyncResult> _syncGpsPoints() async {
    int syncedCount = 0;
    int failedCount = 0;
    String? lastError;

    while (true) {
      final pendingPoints = await _localDb.getPendingGpsPoints(
        limit: _gpsPointBatchSize,
      );

      if (pendingPoints.isEmpty) break;

      try {
        final result = await _supabase.rpc<Map<String, dynamic>>('sync_gps_points', params: {
          'p_points': pendingPoints.map((p) => p.toJson()).toList(),
        },);
        if (result['status'] == 'success') {
          final inserted = result['inserted'] as int? ?? 0;
          syncedCount += inserted;

          // Mark points as synced
          await _localDb.markGpsPointsSynced(
            pendingPoints.map((p) => p.id).toList(),
          );
        } else {
          failedCount += pendingPoints.length;
          lastError = result['message'] as String?;
        }
      } catch (e) {
        failedCount += pendingPoints.length;
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
    final pendingPoints = await _localDb.getPendingGpsPoints();

    return (
      shifts: pendingShifts.length + errorShifts.length,
      gpsPoints: pendingPoints.length,
    );
  }

  /// Clean up old synced data.
  Future<int> cleanupOldData() async {
    final threshold = DateTime.now().subtract(const Duration(days: 30));
    return await _localDb.deleteOldSyncedGpsPoints(threshold);
  }
}
