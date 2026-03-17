import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/local_gps_point.dart';
import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../../shared/services/local_database.dart';
import '../models/sync_progress.dart';
import '../../work_sessions/services/work_session_service.dart';
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

  /// Cooldown tracker: shift server ID -> last trip detection trigger time.
  /// Prevents re-triggering detect_trips for the same shift within 5 minutes.
  final Map<String, DateTime> _tripDetectionCooldowns = {};

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

  WorkSessionService? _workSessionService;

  /// Set the work session service (injected to avoid circular dependencies).
  void setWorkSessionService(WorkSessionService service) {
    _workSessionService = service;
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

    // Step 0: Drain native GPS buffers (Android/iOS backup points)
    await _drainNativeGpsBuffers();

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

    // Trigger trip detection for shifts that had GPS points synced
    if (syncedGpsPoints > 0) {
      _triggerTripDetection(userId);
    }

    // Sync pending lunch breaks
    await _syncLunchBreaks();

    // Sync orphaned work sessions (safety net for mid-request failures)
    await _syncWorkSessions();

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
      final quarantinedPerShift = <String, int>{};

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
              quarantinedPerShift[point.shiftId] = (quarantinedPerShift[point.shiftId] ?? 0) + 1;
            } catch (_) {
              failedCount++;
            }
          } else {
            failedCount++;
          }
        }
      }

      // Log one summary per shift for quarantined points
      for (final entry in quarantinedPerShift.entries) {
        _logger?.sync(Severity.warn, 'Quarantined ${entry.value} orphaned GPS points', metadata: {'shift_id': entry.key, 'count': entry.value, 'reason': 'orphaned_shift'});
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
    if (pendingPoints.isNotEmpty) return true;

    final pendingDiagnostics = await _localDb.getPendingDiagnosticEventCount();
    if (pendingDiagnostics > 0) return true;

    if (_workSessionService != null) {
      final count = await _workSessionService!.getPendingCount(userId);
      if (count > 0) return true;
    }

    return false;
  }

  /// Get count of pending items.
  Future<({int shifts, int gpsPoints, int diagnostics, int workSessions})> getPendingCounts() async {
    final userId = _currentUserId;
    if (userId == null) return (shifts: 0, gpsPoints: 0, diagnostics: 0, workSessions: 0);

    final pendingShifts = await _localDb.getPendingShifts(userId);
    final errorShifts = await _localDb.getErrorShifts(userId);
    final pendingGpsCount = await _localDb.getPendingGpsPointCount();
    final pendingDiagnosticCount = await _localDb.getPendingDiagnosticEventCount();

    int pendingWorkSessionCount = 0;
    if (_workSessionService != null) {
      pendingWorkSessionCount = await _workSessionService!.getPendingCount(userId);
    }

    return (
      shifts: pendingShifts.length + errorShifts.length,
      gpsPoints: pendingGpsCount,
      diagnostics: pendingDiagnosticCount,
      workSessions: pendingWorkSessionCount,
    );
  }

  /// Clean up old synced data.
  Future<int> cleanupOldData() async {
    final threshold = DateTime.now().subtract(const Duration(days: 30));
    return await _localDb.deleteOldSyncedGpsPoints(threshold);
  }

  /// Drains native GPS buffers (Android SharedPreferences / iOS UserDefaults)
  /// and inserts points into local SQLCipher for normal sync pipeline.
  Future<int> _drainNativeGpsBuffers() async {
    try {
      String? json;

      if (Platform.isAndroid) {
        json = await const MethodChannel('gps_tracker/device_manufacturer')
            .invokeMethod<String>('drainNativeGpsBuffer');
      } else if (Platform.isIOS) {
        json = await const MethodChannel('gps_tracker/native_gps_buffer')
            .invokeMethod<String>('drain');
      }

      if (json == null || json == '[]') return 0;

      final points = jsonDecode(json) as List<dynamic>;
      if (points.isEmpty) return 0;

      final userId = _currentUserId;
      if (userId == null) return 0;

      int inserted = 0;
      for (final point in points) {
        final capturedAt = DateTime.fromMillisecondsSinceEpoch(
          point['captured_at'] as int,
        );
        final gpsPoint = LocalGpsPoint(
          id: const Uuid().v4(),
          shiftId: point['shift_id'] as String,
          employeeId: userId,
          latitude: (point['latitude'] as num).toDouble(),
          longitude: (point['longitude'] as num).toDouble(),
          accuracy: (point['accuracy'] as num?)?.toDouble(),
          altitude: (point['altitude'] as num?)?.toDouble(),
          speed: (point['speed'] as num?)?.toDouble(),
          heading: (point['heading'] as num?)?.toDouble(),
          capturedAt: capturedAt,
          syncStatus: 'pending',
          createdAt: capturedAt,
        );
        await _localDb.insertGpsPoint(gpsPoint);
        inserted++;
      }

      if (inserted > 0) {
        _logger?.gps(
          Severity.info,
          'Drained native GPS buffer',
          metadata: {
            'count': inserted,
            'source': points.first['source'],
          },
        );
      }

      return inserted;
    } catch (e) {
      _logger?.gps(
        Severity.warn,
        'Failed to drain native GPS buffer',
        metadata: {'error': e.toString()},
      );
      return 0;
    }
  }

  /// Sync pending lunch breaks to Supabase.
  Future<void> _syncLunchBreaks() async {
    final pendingBreaks = await _localDb.getPendingLunchBreaks();
    if (pendingBreaks.isEmpty) return;

    for (final breakMap in pendingBreaks) {
      try {
        // Map local shift ID to server ID
        final shift = await _localDb.getShiftById(breakMap['shift_id'] as String);
        if (shift == null || shift.serverId == null) continue;

        final result = await _supabase.from('lunch_breaks').upsert({
          'id': breakMap['id'],
          'shift_id': shift.serverId,
          'employee_id': breakMap['employee_id'],
          'started_at': breakMap['started_at'],
          'ended_at': breakMap['ended_at'],
        }, onConflict: 'id').select().single();

        await _localDb.markLunchBreakSynced(
          breakMap['id'] as String,
          result['id'] as String,
        );
      } catch (e) {
        _logger?.sync(Severity.warn, 'Failed to sync lunch break', metadata: {
          'id': breakMap['id'],
          'error': e.toString(),
        });
      }
    }
  }

  /// Sync orphaned work sessions as safety net.
  Future<void> _syncWorkSessions() async {
    final userId = _currentUserId;
    if (userId == null || _workSessionService == null) return;
    try {
      await _workSessionService!.syncPendingSessions(userId);
    } catch (_) {
      // Never let work session sync block the main sync
    }
  }

  /// Trigger trip detection for the most recently completed shift only.
  /// Serialized (awaited) to prevent concurrent DB contention.
  /// Skips shifts already triggered within the last 5 minutes (cooldown).
  /// Called after GPS points sync to detect/re-detect trips with new data.
  Future<void> _triggerTripDetection(String userId) async {
    try {
      // Only fetch the most recently completed shift (not 10).
      // detect_trips is idempotent — older shifts don't need repeated re-detection.
      final recentShifts = await _localDb.getShiftHistory(
        employeeId: userId,
        limit: 1,
        offset: 0,
      );

      if (recentShifts.isEmpty) return;

      final shift = recentShifts.first;
      if (shift.status != 'completed' || shift.serverId == null) return;

      final serverId = shift.serverId!;

      // Cooldown: skip if already triggered within the last 5 minutes
      final lastTriggered = _tripDetectionCooldowns[serverId];
      if (lastTriggered != null) {
        final elapsed = DateTime.now().difference(lastTriggered);
        if (elapsed < const Duration(minutes: 5)) {
          _logger?.sync(
            Severity.debug,
            'Trip detection skipped (cooldown)',
            metadata: {
              'shift_id': serverId,
              'seconds_since_last': elapsed.inSeconds,
            },
          );
          return;
        }
      }

      // Record the trigger time before calling RPCs
      _tripDetectionCooldowns[serverId] = DateTime.now();

      // Prune old cooldown entries (keep only last 20 to avoid unbounded growth)
      if (_tripDetectionCooldowns.length > 20) {
        final sortedEntries = _tripDetectionCooldowns.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final entry
            in sortedEntries.take(_tripDetectionCooldowns.length - 20)) {
          _tripDetectionCooldowns.remove(entry.key);
        }
      }

      // Serialize: await detect_trips, then await detect_carpools
      try {
        await _supabase.rpc<void>(
          'detect_trips',
          params: {'p_shift_id': serverId},
        );
        _logger?.sync(
          Severity.debug,
          'Trip detection completed',
          metadata: {'shift_id': serverId},
        );
      } catch (e) {
        _logger?.sync(
          Severity.warn,
          'Trip detection failed',
          metadata: {'shift_id': serverId, 'error': e.toString()},
        );
        return; // Don't attempt carpool detection if trip detection failed
      }

      try {
        final shiftDate =
            shift.clockedInAt.toIso8601String().substring(0, 10);
        await _supabase.rpc<void>(
          'detect_carpools',
          params: {'p_date': shiftDate},
        );
        _logger?.sync(
          Severity.debug,
          'Carpool detection completed',
          metadata: {'shift_id': serverId, 'date': shiftDate},
        );
      } catch (e) {
        _logger?.sync(
          Severity.warn,
          'Carpool detection failed',
          metadata: {'shift_id': serverId, 'error': e.toString()},
        );
      }
    } catch (e) {
      _logger?.sync(
        Severity.error,
        'Failed to trigger trip detection',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Dispose resources.
  void dispose() {
    _progressController.close();
  }
}
