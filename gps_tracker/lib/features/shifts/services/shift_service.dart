import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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

  ClockInResult({
    required this.success,
    this.shiftId,
    this.clockedInAt,
    this.errorMessage,
    this.isPending = false,
  });

  factory ClockInResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    // Handle shift_id robustly - Supabase may return UUID as various types
    final rawShiftId = json['shift_id'] ?? json['active_shift_id'];
    final shiftId = rawShiftId?.toString();

    return ClockInResult(
      success: status == 'success' || status == 'already_processed',
      shiftId: shiftId,
      clockedInAt: json['clocked_in_at'] != null
          ? DateTime.parse(json['clocked_in_at'].toString())
          : null,
      errorMessage: json['message']?.toString(),
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

  /// Clock in - creates a new shift locally first, then syncs.
  /// Requires a valid GPS location to proceed.
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

    // Write to local database first
    await _localDb.insertShift(localShift);

    // Try to sync to Supabase
    try {
      final response = await _supabase.rpc<Map<String, dynamic>>('clock_in', params: {
        'p_request_id': requestId,
        'p_location': location.toJson(),
        if (accuracy != null) 'p_accuracy': accuracy,
      },);

      final result = ClockInResult.fromJson(response);

      if (result.success && result.shiftId != null) {
        // Mark as synced only if we have a valid server ID
        await _localDb.markShiftSynced(shiftId, serverId: result.shiftId);
        return ClockInResult(
          success: true,
          shiftId: shiftId,
          clockedInAt: now,
        );
      } else if (result.success) {
        // Success but no server ID - keep as pending
        return ClockInResult(
          success: true,
          shiftId: shiftId,
          clockedInAt: now,
          isPending: true,
        );
      } else if (result.shiftId != null) {
        // Server has an active shift - auto clock-out and retry clock-in
        final existingServerId = result.shiftId!;

        // Clock out the existing server shift
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

        // If retry failed, keep as pending
        return ClockInResult(
          success: true,
          shiftId: shiftId,
          clockedInAt: now,
          isPending: true,
        );
      } else {
        // Mark sync error but shift still exists locally
        await _localDb.markShiftSyncError(shiftId, result.errorMessage ?? 'Unknown error');
        return ClockInResult(
          success: true, // Still success because local shift was created
          shiftId: shiftId,
          clockedInAt: now,
          isPending: true,
        );
      }
    } catch (e) {
      // Network error - shift is pending sync
      return ClockInResult.pending(shiftId);
    }
  }

  /// Clock out - updates shift locally first, then syncs.
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

    // Update local shift first
    await _localDb.updateShiftClockOut(
      shiftId: shiftId,
      clockedOutAt: now,
      latitude: location?.latitude,
      longitude: location?.longitude,
      accuracy: accuracy,
      reason: reason,
    );

    // Try to sync to Supabase
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
        await _localDb.markShiftSynced(shiftId);
        return ClockOutResult(
          success: true,
          shiftId: shiftId,
          clockedOutAt: now,
        );
      } else {
        await _localDb.markShiftSyncError(shiftId, result.errorMessage ?? 'Unknown error');
        return ClockOutResult(
          success: true,
          shiftId: shiftId,
          clockedOutAt: now,
          isPending: true,
        );
      }
    } catch (e) {
      return ClockOutResult.pending(shiftId);
    }
  }

  /// Get the current active shift.
  Future<Shift?> getActiveShift() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    final localShift = await _localDb.getActiveShift(userId);
    return localShift?.toShift();
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
}
