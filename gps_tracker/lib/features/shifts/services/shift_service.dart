import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../../shared/services/local_database.dart';
import '../models/geo_point.dart';
import '../models/local_shift.dart';
import '../models/shift.dart';

/// Result of a clock-in operation.
class ClockInResult {
  final bool success;
  final String? shiftId;
  final DateTime? clockedInAt;
  final String? errorMessage;
  final bool isPending;
  final bool isReopened;

  ClockInResult({
    required this.success,
    this.shiftId,
    this.clockedInAt,
    this.errorMessage,
    this.isPending = false,
    this.isReopened = false,
  });

  factory ClockInResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    // Handle shift_id robustly - Supabase may return UUID as various types
    final rawShiftId = json['shift_id'] ?? json['active_shift_id'];
    final shiftId = rawShiftId?.toString();

    return ClockInResult(
      success: status == 'success' || status == 'already_processed' || status == 'reopened',
      shiftId: shiftId,
      clockedInAt: json['clocked_in_at'] != null
          ? DateTime.parse(json['clocked_in_at'].toString())
          : null,
      errorMessage: json['message']?.toString(),
      isReopened: status == 'reopened',
    );
  }

  factory ClockInResult.pending(String shiftId) => ClockInResult(
        success: true,
        shiftId: shiftId,
        isPending: true,
      );

  factory ClockInResult.error(String message) => ClockInResult(
        success: false,
        errorMessage: message,
      );
}

/// Result of a clock-out operation.
class ClockOutResult {
  final bool success;
  final String? shiftId;
  final DateTime? clockedOutAt;
  final String? errorMessage;
  final bool isPending;

  ClockOutResult({
    required this.success,
    this.shiftId,
    this.clockedOutAt,
    this.errorMessage,
    this.isPending = false,
  });

  factory ClockOutResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    // Handle shift_id robustly - Supabase may return UUID as various types
    final shiftId = json['shift_id']?.toString();

    return ClockOutResult(
      success: status == 'success' || status == 'already_processed',
      shiftId: shiftId,
      clockedOutAt: json['clocked_out_at'] != null
          ? DateTime.parse(json['clocked_out_at'].toString())
          : null,
      errorMessage: json['message']?.toString(),
    );
  }

  factory ClockOutResult.pending(String shiftId) => ClockOutResult(
        success: true,
        shiftId: shiftId,
        isPending: true,
      );

  factory ClockOutResult.error(String message) => ClockOutResult(
        success: false,
        errorMessage: message,
      );
}

/// Service for shift operations with local-first architecture.
class ShiftService {
  final SupabaseClient _supabase;
  final LocalDatabase _localDb;
  final Uuid _uuid;

  ShiftService(this._supabase, this._localDb) : _uuid = const Uuid();

  /// Get the current user ID.
  String? get _currentUserId => _supabase.auth.currentUser?.id;

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Clock in - requires server confirmation before showing success.
  /// Creates a local shift, then waits for server to confirm.
  /// If the server is unreachable, returns an error so the UI can retry.
  Future<ClockInResult> clockIn({
    required GeoPoint location,
    double? accuracy,
  }) async {
    final userId = _currentUserId;
    if (userId == null) {
      return ClockInResult.error('Not authenticated');
    }

    // Check if already clocked in locally
    final existingShift = await _localDb.getActiveShift(userId);
    if (existingShift != null) {
      return ClockInResult.error('Already clocked in');
    }

    // Generate IDs
    final shiftId = _uuid.v4();
    final requestId = _uuid.v4();
    final now = DateTime.now().toUtc();

    // Create local shift
    final localShift = LocalShift(
      id: shiftId,
      employeeId: userId,
      requestId: requestId,
      status: 'active',
      clockedInAt: now,
      clockInLatitude: location.latitude,
      clockInLongitude: location.longitude,
      clockInAccuracy: accuracy,
      syncStatus: 'pending',
      createdAt: now,
      updatedAt: now,
    );

    // Write to local database first (crash safety)
    await _localDb.insertShift(localShift);

    // Server confirmation required — don't show success until server responds
    try {
      final response = await _supabase.rpc<Map<String, dynamic>>('clock_in', params: {
        'p_request_id': requestId,
        'p_location': location.toJson(),
        if (accuracy != null) 'p_accuracy': accuracy,
      },);

      final result = ClockInResult.fromJson(response);

      if (result.success && result.isReopened && result.shiftId != null) {
        // Server reopened a recently-closed shift — delete the new local shift
        // and reopen the old one so the timer continues from the original time
        await _localDb.deleteShift(shiftId);
        await _localDb.reopenShiftByServerId(result.shiftId!);
        final reopenedShift = await _localDb.getShiftByServerId(result.shiftId!);
        _logger?.shift(Severity.info, 'Clock in reopened recent shift', metadata: {
          'reopened_server_id': result.shiftId,
          'original_clocked_in_at': result.clockedInAt?.toIso8601String(),
        });
        return ClockInResult(
          success: true,
          shiftId: reopenedShift?.id ?? shiftId,
          clockedInAt: result.clockedInAt ?? now,
          isReopened: true,
        );
      } else if (result.success && result.shiftId != null) {
        // Server confirmed — mark as synced
        await _localDb.markShiftSynced(shiftId, serverId: result.shiftId);
        return ClockInResult(
          success: true,
          shiftId: shiftId,
          clockedInAt: now,
        );
      } else if (result.success) {
        // Server returned success but no shift ID — treat as confirmed
        return ClockInResult(
          success: true,
          shiftId: shiftId,
          clockedInAt: now,
        );
      } else if (result.shiftId != null) {
        // Server has an active shift — auto clock-out and retry
        // (This should be rare now that clock_in RPC auto-closes stale shifts)
        final existingServerId = result.shiftId!;

        await _supabase.rpc<Map<String, dynamic>>('clock_out', params: {
          'p_shift_id': existingServerId,
          'p_request_id': _uuid.v4(),
          'p_location': location.toJson(),
          if (accuracy != null) 'p_accuracy': accuracy,
        },);

        // Retry clock-in with the same request
        final retryResponse = await _supabase.rpc<Map<String, dynamic>>('clock_in', params: {
          'p_request_id': requestId,
          'p_location': location.toJson(),
          if (accuracy != null) 'p_accuracy': accuracy,
        },);

        final retryResult = ClockInResult.fromJson(retryResponse);
        if (retryResult.shiftId != null) {
          await _localDb.markShiftSynced(shiftId, serverId: retryResult.shiftId);
          return ClockInResult(
            success: true,
            shiftId: shiftId,
            clockedInAt: now,
          );
        }

        // Retry also failed — remove local shift so user can retry cleanly
        await _localDb.deleteShift(shiftId);
        return ClockInResult.error(
          retryResult.errorMessage ?? 'Server rejected clock-in',
        );
      } else {
        // Server returned an error — remove local shift so user can retry
        await _localDb.deleteShift(shiftId);
        return ClockInResult.error(
          result.errorMessage ?? 'Server rejected clock-in',
        );
      }
    } catch (e) {
      // Network error — remove local shift so user can retry cleanly
      await _localDb.deleteShift(shiftId);
      return ClockInResult.error(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
  }

  /// Clock out - requires server confirmation before showing success.
  /// Updates local shift, then waits for server to confirm.
  /// If the server is unreachable, reverts local state and returns error.
  Future<ClockOutResult> clockOut({
    required String shiftId,
    GeoPoint? location,
    double? accuracy,
    String? reason,
  }) async {
    final userId = _currentUserId;
    if (userId == null) {
      return ClockOutResult.error('Not authenticated');
    }

    // Verify shift exists and is active
    final existingShift = await _localDb.getShiftById(shiftId);
    if (existingShift == null) {
      return ClockOutResult.error('Shift not found');
    }
    if (existingShift.status != 'active') {
      return ClockOutResult.error('Shift already completed');
    }

    final requestId = _uuid.v4();
    final now = DateTime.now().toUtc();

    // Server confirmation required — call server first
    try {
      final response = await _supabase.rpc<Map<String, dynamic>>('clock_out', params: {
        'p_shift_id': existingShift.serverId ?? shiftId,
        'p_request_id': requestId,
        if (location != null) 'p_location': location.toJson(),
        if (accuracy != null) 'p_accuracy': accuracy,
        if (reason != null) 'p_reason': reason,
      },);

      final result = ClockOutResult.fromJson(response);

      if (result.success) {
        // Server confirmed — now update local DB
        await _localDb.updateShiftClockOut(
          shiftId: shiftId,
          clockedOutAt: now,
          latitude: location?.latitude,
          longitude: location?.longitude,
          accuracy: accuracy,
          reason: reason,
        );
        await _localDb.markShiftSynced(shiftId);

        // Fire-and-forget trip detection for mileage tracking
        final serverShiftId = existingShift.serverId ?? shiftId;
        _detectTripsAsync(serverShiftId);

        return ClockOutResult(
          success: true,
          shiftId: shiftId,
          clockedOutAt: now,
        );
      } else {
        return ClockOutResult.error(
          result.errorMessage ?? 'Server rejected clock-out',
        );
      }
    } catch (e) {
      // Network error — don't update local DB, keep shift active so UI stays consistent
      return ClockOutResult.error(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
  }

  /// Get the current active shift.
  Future<Shift?> getActiveShift() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    final localShift = await _localDb.getActiveShift(userId);
    return localShift?.toShift();
  }

  /// Reconcile local shift state with the server.
  ///
  /// Handles scenarios where local and server state diverge:
  /// - App reinstalled while shift active → resume server shift locally
  /// - Server closed shift (midnight cleanup, admin) → close local shift
  /// - Stale server shift (before last midnight) → close on server
  ///
  /// Fail-open: if server is unreachable, returns local state unchanged.
  Future<LocalShift?> reconcileShiftState() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    // 1. Load local active shift
    final localShift = await _localDb.getActiveShift(userId);

    // 2. Query server for active shift (fail-open)
    Map<String, dynamic>? serverShift;
    try {
      serverShift = await _supabase
          .from('shifts')
          .select('id, employee_id, status, clocked_in_at, clock_in_location, clock_in_accuracy, created_at, updated_at')
          .eq('employee_id', userId)
          .eq('status', 'active')
          .maybeSingle();
    } catch (e) {
      _logger?.shift(Severity.debug, 'Reconciliation skipped: server unreachable', metadata: {
        'error': e.toString(),
      },);
      return localShift;
    }

    // 3. Both null → nothing to do
    if (localShift == null && serverShift == null) return null;

    // 4. Local active, server matches → already synced
    if (localShift != null && serverShift != null && localShift.serverId == serverShift['id']) {
      return localShift;
    }

    // 5. No local shift, server has active shift → resume or close
    if (localShift == null && serverShift != null) {
      final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
      final lastMidnight = _lastMidnightET();

      if (clockedInAt.isAfter(lastMidnight)) {
        // Recent shift — resume locally
        _logger?.shift(Severity.info, 'Resumed orphaned server shift', metadata: {
          'server_id': serverShift['id'],
          'clocked_in_at': clockedInAt.toIso8601String(),
        },);
        return await _resumeServerShift(userId, serverShift);
      } else {
        // Stale shift (before midnight) — close on server
        _logger?.shift(Severity.warn, 'Closed stale server shift', metadata: {
          'server_id': serverShift['id'],
          'clocked_in_at': clockedInAt.toIso8601String(),
          'last_midnight': lastMidnight.toIso8601String(),
        },);
        await _closeStaleServerShift(serverShift['id'] as String);
        return null;
      }
    }

    // 6. Local active, no server shift (or server completed) → close local
    if (localShift != null && serverShift == null) {
      _logger?.shift(Severity.warn, 'Closed orphaned local shift', metadata: {
        'shift_id': localShift.id,
        'server_id': localShift.serverId,
      },);
      await _localDb.updateShiftClockOut(
        shiftId: localShift.id,
        clockedOutAt: DateTime.now().toUtc(),
        reason: 'server_reconciliation',
      );
      await _localDb.markShiftSynced(localShift.id);
      return null;
    }

    // 7. Local active, server active but different shift → close local, handle server shift
    if (localShift != null && serverShift != null && localShift.serverId != serverShift['id']) {
      // Close the local orphan
      _logger?.shift(Severity.warn, 'Closed orphaned local shift', metadata: {
        'shift_id': localShift.id,
        'server_id': localShift.serverId,
      },);
      await _localDb.updateShiftClockOut(
        shiftId: localShift.id,
        clockedOutAt: DateTime.now().toUtc(),
        reason: 'server_reconciliation',
      );
      await _localDb.markShiftSynced(localShift.id);

      // Resume the server shift if recent
      final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
      final lastMidnight = _lastMidnightET();
      if (clockedInAt.isAfter(lastMidnight)) {
        _logger?.shift(Severity.info, 'Resumed orphaned server shift', metadata: {
          'server_id': serverShift['id'],
          'clocked_in_at': clockedInAt.toIso8601String(),
        },);
        return await _resumeServerShift(userId, serverShift);
      } else {
        _logger?.shift(Severity.warn, 'Closed stale server shift', metadata: {
          'server_id': serverShift['id'],
          'clocked_in_at': clockedInAt.toIso8601String(),
          'last_midnight': lastMidnight.toIso8601String(),
        },);
        await _closeStaleServerShift(serverShift['id'] as String);
        return null;
      }
    }

    return localShift;
  }

  /// Calculate last midnight in America/Montreal timezone (Eastern).
  DateTime _lastMidnightET() {
    final now = DateTime.now().toUtc();
    // Eastern Time is UTC-5 (EST) or UTC-4 (EDT)
    // Use -5 (EST) as conservative offset — worst case we resume a shift
    // that's slightly older, which is safer than closing a valid one
    const etOffset = Duration(hours: -5);
    final nowET = now.add(etOffset);
    final midnightET = DateTime(nowET.year, nowET.month, nowET.day);
    // Convert back to UTC
    return midnightET.subtract(etOffset);
  }

  /// Resume a server shift by creating a local copy.
  Future<LocalShift> _resumeServerShift(String userId, Map<String, dynamic> serverShift) async {
    final serverId = serverShift['id'] as String;
    final clockedInAt = DateTime.parse(serverShift['clocked_in_at'] as String);
    final now = DateTime.now().toUtc();

    // Parse clock-in location if available
    double? lat, lng;
    final locJson = serverShift['clock_in_location'];
    if (locJson is Map<String, dynamic>) {
      lat = (locJson['latitude'] as num?)?.toDouble();
      lng = (locJson['longitude'] as num?)?.toDouble();
    }
    final accuracy = (serverShift['clock_in_accuracy'] as num?)?.toDouble();

    final localShift = LocalShift(
      id: _uuid.v4(), // New local ID
      employeeId: userId,
      status: 'active',
      clockedInAt: clockedInAt,
      clockInLatitude: lat,
      clockInLongitude: lng,
      clockInAccuracy: accuracy,
      syncStatus: 'synced', // Already exists on server
      serverId: serverId,
      createdAt: now,
      updatedAt: now,
    );

    await _localDb.insertShift(localShift);
    debugPrint('[ShiftService] Resumed server shift $serverId locally as ${localShift.id}');
    return localShift;
  }

  /// Close a stale server shift (clocked in before last midnight).
  Future<void> _closeStaleServerShift(String serverId) async {
    try {
      await _supabase
          .from('shifts')
          .update({
            'status': 'completed',
            'clocked_out_at': DateTime.now().toUtc().toIso8601String(),
            'clock_out_reason': 'stale_reconciliation',
          })
          .eq('id', serverId)
          .eq('status', 'active');
      debugPrint('[ShiftService] Closed stale server shift $serverId');
    } catch (e) {
      debugPrint('[ShiftService] Failed to close stale server shift $serverId: $e');
    }
  }

  /// Get shift history with pagination.
  Future<List<Shift>> getShiftHistory({int limit = 50, int offset = 0}) async {
    final userId = _currentUserId;
    if (userId == null) return [];

    final localShifts = await _localDb.getShiftHistory(
      employeeId: userId,
      limit: limit,
      offset: offset,
    );
    return localShifts.map((s) => s.toShift()).toList();
  }

  /// Get a specific shift by ID.
  Future<Shift?> getShiftById(String shiftId) async {
    final localShift = await _localDb.getShiftById(shiftId);
    return localShift?.toShift();
  }

  /// Get pending shifts that need sync.
  Future<List<Shift>> getPendingShifts() async {
    final userId = _currentUserId;
    if (userId == null) return [];

    final localShifts = await _localDb.getPendingShifts(userId);
    return localShifts.map((s) => s.toShift()).toList();
  }

  /// Sync a specific shift to Supabase.
  Future<bool> syncShift(String shiftId) async {
    final shift = await _localDb.getShiftById(shiftId);
    if (shift == null) return false;

    await _localDb.markShiftSyncing(shiftId);

    try {
      if (shift.status == 'active') {
        // Sync clock-in
        final response = await _supabase.rpc<Map<String, dynamic>>('clock_in', params: {
          'p_request_id': shift.requestId,
          if (shift.clockInLatitude != null && shift.clockInLongitude != null)
            'p_location': {
              'latitude': shift.clockInLatitude,
              'longitude': shift.clockInLongitude,
            },
          if (shift.clockInAccuracy != null) 'p_accuracy': shift.clockInAccuracy,
        },);

        final result = ClockInResult.fromJson(response);
        if (result.shiftId != null) {
          // Got a server ID (success, already_processed, or active_shift_id)
          await _localDb.markShiftSynced(shiftId, serverId: result.shiftId);
          return true;
        } else if (result.success) {
          // Success but no server ID - keep as pending for retry
          await _localDb.markShiftSyncError(shiftId, 'No server ID returned');
          return false;
        } else {
          await _localDb.markShiftSyncError(shiftId, result.errorMessage ?? 'Unknown error');
          return false;
        }
      } else {
        // For completed shifts, sync both clock-in and clock-out
        // First sync clock-in if not already synced
        if (shift.syncStatus != 'synced') {
          final clockInResponse = await _supabase.rpc<Map<String, dynamic>>('clock_in', params: {
            'p_request_id': shift.requestId,
            if (shift.clockInLatitude != null && shift.clockInLongitude != null)
              'p_location': {
                'latitude': shift.clockInLatitude,
                'longitude': shift.clockInLongitude,
              },
            if (shift.clockInAccuracy != null) 'p_accuracy': shift.clockInAccuracy,
          },);

          final clockInResult = ClockInResult.fromJson(clockInResponse);
          // Accept any response that includes a server shift ID
          if (clockInResult.shiftId == null) {
            await _localDb.markShiftSyncError(
              shiftId,
              clockInResult.errorMessage ?? 'No server ID returned',
            );
            return false;
          }

          // Then sync clock-out using server shift ID
          final clockOutResponse = await _supabase.rpc<Map<String, dynamic>>('clock_out', params: {
            'p_shift_id': clockInResult.shiftId,
            'p_request_id': _uuid.v4(),
            if (shift.clockOutLatitude != null && shift.clockOutLongitude != null)
              'p_location': {
                'latitude': shift.clockOutLatitude,
                'longitude': shift.clockOutLongitude,
              },
            if (shift.clockOutAccuracy != null) 'p_accuracy': shift.clockOutAccuracy,
            if (shift.clockOutReason != null) 'p_reason': shift.clockOutReason,
          },);

          final clockOutResult = ClockOutResult.fromJson(clockOutResponse);
          if (clockOutResult.success) {
            await _localDb.markShiftSynced(shiftId, serverId: clockInResult.shiftId);
            return true;
          } else {
            await _localDb.markShiftSyncError(shiftId, clockOutResult.errorMessage ?? 'Unknown error');
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      await _localDb.markShiftSyncError(shiftId, e.toString());
      return false;
    }
  }

  /// Fire-and-forget trip detection for mileage tracking.
  /// Called after successful clock-out to detect vehicle trips from GPS points.
  void _detectTripsAsync(String serverShiftId) {
    _supabase.rpc('detect_trips', params: {
      'p_shift_id': serverShiftId,
    }).then((_) {
      debugPrint('[Mileage] Trip detection completed for shift $serverShiftId');
    }).catchError((e) {
      debugPrint('[Mileage] Trip detection failed for shift $serverShiftId: $e');
    });
  }
}
