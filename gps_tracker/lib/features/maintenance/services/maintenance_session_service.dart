import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../cleaning/services/cleaning_local_db.dart';
import '../../shifts/models/shift_enums.dart';
import '../models/maintenance_session.dart';
import 'maintenance_local_db.dart';

/// Service for maintenance session lifecycle with local-first architecture.
class MaintenanceSessionService {
  final SupabaseClient _supabase;
  final MaintenanceLocalDb _localDb;
  final CleaningLocalDb _cleaningLocalDb;
  final Uuid _uuid;

  MaintenanceSessionService(
    this._supabase,
    this._localDb,
    this._cleaningLocalDb,
  ) : _uuid = const Uuid();

  /// Start a maintenance session for a building (and optionally an apartment).
  Future<MaintenanceSessionResult> startSession({
    required String employeeId,
    required String shiftId,
    required String buildingId,
    required String buildingName,
    String? apartmentId,
    String? unitNumber,
    String? serverShiftId,
    double? latitude,
    double? longitude,
    double? accuracy,
  }) async {
    // 1. Check for active cleaning session (cross-feature)
    final activeCleaning =
        await _cleaningLocalDb.getActiveSessionForEmployee(employeeId);
    if (activeCleaning != null) {
      return MaintenanceSessionResult.error(
        'Terminez votre session de ménage avant de commencer un entretien',
      );
    }

    // 2. Check for active maintenance session (one at a time)
    final activeMaintenance =
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (activeMaintenance != null) {
      return MaintenanceSessionResult.error(
        'Une session d\'entretien est déjà en cours',
      );
    }

    // 3. Create local maintenance session
    final sessionId = _uuid.v4();
    final now = DateTime.now().toUtc();

    final session = MaintenanceSession(
      id: sessionId,
      employeeId: employeeId,
      shiftId: shiftId,
      buildingId: buildingId,
      apartmentId: apartmentId,
      status: MaintenanceSessionStatus.inProgress,
      startedAt: now,
      syncStatus: SyncStatus.pending,
      startLatitude: latitude,
      startLongitude: longitude,
      startAccuracy: accuracy,
      buildingName: buildingName,
      unitNumber: unitNumber,
    );

    await _localDb.insertMaintenanceSession(session);

    // 4. Attempt Supabase RPC
    try {
      final params = <String, dynamic>{
        'p_employee_id': employeeId,
        'p_shift_id': serverShiftId ?? shiftId,
        'p_building_id': buildingId,
      };
      if (apartmentId != null) {
        params['p_apartment_id'] = apartmentId;
      }

      final response =
          await _supabase.rpc<Map<String, dynamic>>('start_maintenance',
              params: params);

      if (response['success'] == true) {
        final serverId = response['session_id'] as String?;
        if (serverId != null) {
          await _localDb.markMaintenanceSessionSynced(sessionId,
              serverId: serverId);
        }
        return MaintenanceSessionResult.success(
          session.copyWith(syncStatus: SyncStatus.synced),
        );
      } else {
        // Server rejected — return the error but keep local session
        final errorMsg =
            response['message'] as String? ?? 'Erreur serveur';
        return MaintenanceSessionResult.success(session, warning: errorMsg);
      }
    } catch (e) {
      // ignore: avoid_print
      print('MaintenanceSessionService.startSession RPC error: $e');
      // Network error — session is pending sync
      return MaintenanceSessionResult.success(session);
    }
  }

  /// Complete the active maintenance session.
  Future<MaintenanceSessionResult> completeSession({
    required String employeeId,
    double? latitude,
    double? longitude,
    double? accuracy,
  }) async {
    final activeSession =
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (activeSession == null) {
      return MaintenanceSessionResult.error(
          'Aucune session d\'entretien active');
    }

    final now = DateTime.now().toUtc();
    final durationMinutes =
        now.difference(activeSession.startedAt).inSeconds / 60.0;

    final completedSession = activeSession.copyWith(
      status: MaintenanceSessionStatus.completed,
      completedAt: now,
      durationMinutes: durationMinutes,
      syncStatus: SyncStatus.pending,
      endLatitude: latitude,
      endLongitude: longitude,
      endAccuracy: accuracy,
    );
    await _localDb.updateMaintenanceSession(completedSession);

    // Attempt Supabase RPC
    try {
      final response = await _supabase
          .rpc<Map<String, dynamic>>('complete_maintenance', params: {
        'p_employee_id': employeeId,
      });

      if (response['success'] == true) {
        await _localDb.markMaintenanceSessionSynced(activeSession.id);
        return MaintenanceSessionResult.success(
          completedSession.copyWith(syncStatus: SyncStatus.synced),
        );
      }
    } catch (e) {
      // ignore: avoid_print
      print('MaintenanceSessionService.completeSession RPC error: $e');
      // Network error — session is pending sync
    }

    return MaintenanceSessionResult.success(completedSession);
  }

  /// Manually close the active maintenance session.
  Future<MaintenanceSession?> manualClose({
    required String employeeId,
  }) async {
    final activeSession =
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (activeSession == null) return null;

    final now = DateTime.now().toUtc();
    final durationMinutes =
        now.difference(activeSession.startedAt).inSeconds / 60.0;

    final closedSession = activeSession.copyWith(
      status: MaintenanceSessionStatus.manuallyClosed,
      completedAt: now,
      durationMinutes: durationMinutes,
      syncStatus: SyncStatus.pending,
    );
    await _localDb.updateMaintenanceSession(closedSession);

    // Try to sync to Supabase
    try {
      await _supabase.rpc('manually_close_maintenance_session', params: {
        'p_employee_id': employeeId,
        'p_session_id': activeSession.id,
        'p_closed_at': now.toIso8601String(),
      });
      await _localDb.markMaintenanceSessionSynced(activeSession.id);
      return closedSession.copyWith(syncStatus: SyncStatus.synced);
    } catch (_) {
      return closedSession;
    }
  }

  /// Auto-close all open maintenance sessions when shift ends.
  /// [shiftId] is used for both local queries and Supabase RPC.
  /// Pass the local shift ID — the service resolves the server ID internally.
  Future<int> autoCloseSessions({
    required String shiftId,
    required String employeeId,
    required DateTime closedAt,
  }) async {
    final sessions =
        await _localDb.getInProgressSessionsForShift(shiftId, employeeId);

    for (final session in sessions) {
      final durationMinutes =
          closedAt.difference(session.startedAt).inSeconds / 60.0;

      final closedSession = session.copyWith(
        status: MaintenanceSessionStatus.autoClosed,
        completedAt: closedAt,
        durationMinutes: durationMinutes,
        syncStatus: SyncStatus.pending,
      );
      await _localDb.updateMaintenanceSession(closedSession);
    }

    // Attempt Supabase sync — resolve server shift ID
    try {
      final serverShiftId = await _localDb.resolveServerShiftId(shiftId);
      if (serverShiftId != null) {
        await _supabase.rpc('auto_close_maintenance_sessions', params: {
          'p_shift_id': serverShiftId,
          'p_employee_id': employeeId,
          'p_closed_at': closedAt.toIso8601String(),
        });

        for (final session in sessions) {
          await _localDb.markMaintenanceSessionSynced(session.id);
        }
      }
    } catch (_) {
      // Will be synced later
    }

    return sessions.length;
  }

  /// Get the current active maintenance session for the employee.
  Future<MaintenanceSession?> getActiveSession(String employeeId) async {
    return _localDb.getActiveSessionForEmployee(employeeId);
  }

  /// Get all maintenance sessions for a shift.
  Future<List<MaintenanceSession>> getShiftSessions(String shiftId) async {
    return _localDb.getSessionsForShift(shiftId);
  }

  /// Sync all pending local sessions to Supabase.
  Future<void> syncPendingSessions(String employeeId) async {
    final pending =
        await _localDb.getPendingMaintenanceSessions(employeeId);

    for (final session in pending) {
      try {
        // Resolve server shift ID
        final serverShiftId =
            await _localDb.resolveServerShiftId(session.shiftId);
        if (serverShiftId == null) {
          // Shift not synced yet — skip, will retry later
          continue;
        }

        if (session.status == MaintenanceSessionStatus.inProgress) {
          // Sync start with correct server shift ID
          final params = <String, dynamic>{
            'p_employee_id': session.employeeId,
            'p_shift_id': serverShiftId,
            'p_building_id': session.buildingId,
          };
          if (session.apartmentId != null) {
            params['p_apartment_id'] = session.apartmentId;
          }

          final response = await _supabase
              .rpc<Map<String, dynamic>>('start_maintenance', params: params);

          if (response['success'] == true) {
            await _localDb.markMaintenanceSessionSynced(session.id,
                serverId: response['session_id'] as String?);
          } else {
            await _localDb.markMaintenanceSessionSyncError(session.id);
          }
        } else {
          // Completed/auto-closed/manually-closed: direct insert
          await _supabase.from('maintenance_sessions').insert({
            'employee_id': session.employeeId,
            'shift_id': serverShiftId,
            'building_id': session.buildingId,
            'apartment_id': session.apartmentId,
            'status': session.status.toJson(),
            'started_at': session.startedAt.toUtc().toIso8601String(),
            'completed_at':
                session.completedAt?.toUtc().toIso8601String(),
            'duration_minutes': session.durationMinutes,
            if (session.startLatitude != null)
              'start_latitude': session.startLatitude,
            if (session.startLongitude != null)
              'start_longitude': session.startLongitude,
            if (session.startAccuracy != null)
              'start_accuracy': session.startAccuracy,
            if (session.endLatitude != null)
              'end_latitude': session.endLatitude,
            if (session.endLongitude != null)
              'end_longitude': session.endLongitude,
            if (session.endAccuracy != null)
              'end_accuracy': session.endAccuracy,
          });

          await _localDb.markMaintenanceSessionSynced(session.id);
        }
      } catch (_) {
        await _localDb.markMaintenanceSessionSyncError(session.id);
      }
    }
  }
}

/// Result of a maintenance session operation.
class MaintenanceSessionResult {
  final bool success;
  final MaintenanceSession? session;
  final String? errorMessage;
  final String? warning;

  const MaintenanceSessionResult._({
    required this.success,
    this.session,
    this.errorMessage,
    this.warning,
  });

  factory MaintenanceSessionResult.success(
    MaintenanceSession session, {
    String? warning,
  }) =>
      MaintenanceSessionResult._(
        success: true,
        session: session,
        warning: warning,
      );

  factory MaintenanceSessionResult.error(String message) =>
      MaintenanceSessionResult._(
        success: false,
        errorMessage: message,
      );
}
