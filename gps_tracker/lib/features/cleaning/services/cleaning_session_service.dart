import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../shifts/models/shift_enums.dart';
import '../models/cleaning_session.dart';
import '../models/scan_result.dart';
import '../models/studio.dart';
import 'cleaning_local_db.dart';
import 'studio_cache_service.dart';

/// Service for cleaning session lifecycle with local-first architecture.
/// Follows the same pattern as ShiftService.
class CleaningSessionService {
  final SupabaseClient _supabase;
  final CleaningLocalDb _localDb;
  final StudioCacheService _studioCache;
  final Uuid _uuid;

  CleaningSessionService(this._supabase, this._localDb, this._studioCache)
      : _uuid = const Uuid();

  /// Get the current user ID.
  String? get _currentUserId => _supabase.auth.currentUser?.id;

  /// Start a cleaning session by scanning a QR code.
  Future<ScanResult> scanIn({
    required String employeeId,
    required String qrCode,
    required String shiftId,
  }) async {
    // 1. Look up studio by QR code in local cache
    Studio? studio = await _studioCache.lookupByQrCode(qrCode);

    // 2. If not found locally, try Supabase lookup and update cache
    if (studio == null) {
      try {
        final response = await _supabase
            .from('studios')
            .select(
                'id, qr_code, studio_number, building_id, studio_type, is_active, buildings!inner(name)')
            .eq('qr_code', qrCode)
            .maybeSingle();

        if (response != null) {
          final buildingName =
              response['buildings']?['name'] as String? ?? '';
          studio = Studio(
            id: response['id'] as String,
            qrCode: response['qr_code'] as String,
            studioNumber: response['studio_number'] as String,
            buildingId: response['building_id'] as String,
            buildingName: buildingName,
            studioType: StudioType.fromJson(
                response['studio_type'] as String? ?? 'unit'),
            isActive: response['is_active'] as bool? ?? true,
          );
          // Update local cache
          await _localDb.upsertStudios([studio]);
        }
      } catch (_) {
        // Network error - studio not in cache and offline
      }
    }

    // 3. If still not found → INVALID_QR
    if (studio == null) {
      return ScanResult.error(ScanErrorType.invalidQr);
    }

    // 4. Check if studio is active
    if (!studio.isActive) {
      return ScanResult.error(ScanErrorType.studioInactive);
    }

    // 5. Check for existing active session for this employee + studio
    final existingSession = await _localDb.getActiveSessionForEmployee(
      employeeId,
      studioId: studio.id,
    );
    if (existingSession != null) {
      return ScanResult.error(
        ScanErrorType.sessionExists,
        existingSessionId: existingSession.id,
      );
    }

    // 6. Create local cleaning session
    final sessionId = _uuid.v4();
    final now = DateTime.now().toUtc();

    final session = CleaningSession(
      id: sessionId,
      employeeId: employeeId,
      studioId: studio.id,
      shiftId: shiftId,
      status: CleaningSessionStatus.inProgress,
      startedAt: now,
      syncStatus: SyncStatus.pending,
      studioNumber: studio.studioNumber,
      buildingName: studio.buildingName,
      studioType: studio.studioType,
    );

    await _localDb.insertCleaningSession(session);

    // 7. Attempt Supabase RPC scan_in
    try {
      final response =
          await _supabase.rpc<Map<String, dynamic>>('scan_in', params: {
        'p_employee_id': employeeId,
        'p_qr_code': qrCode,
        'p_shift_id': shiftId,
      });

      if (response['success'] == true) {
        final serverId = response['session_id'] as String?;
        if (serverId != null) {
          await _localDb.markCleaningSessionSynced(sessionId,
              serverId: serverId);
        }
        return ScanResult.success(
          session.copyWith(syncStatus: SyncStatus.synced),
        );
      } else {
        // Server rejected but we still have local session
        return ScanResult.success(session);
      }
    } catch (_) {
      // Network error - session is pending sync
      return ScanResult.success(session);
    }
  }

  /// Complete a cleaning session by scanning the same QR code.
  Future<ScanResult> scanOut({
    required String employeeId,
    required String qrCode,
  }) async {
    // 1. Look up studio by QR code
    final studio = await _studioCache.lookupByQrCode(qrCode);
    if (studio == null) {
      return ScanResult.error(ScanErrorType.invalidQr);
    }

    // 2. Find active local session for this employee + studio
    final activeSession = await _localDb.getActiveSessionForEmployee(
      employeeId,
      studioId: studio.id,
    );
    if (activeSession == null) {
      return ScanResult.error(ScanErrorType.noActiveSession);
    }

    // 3. Compute completion data
    final now = DateTime.now().toUtc();
    final durationMinutes =
        now.difference(activeSession.startedAt).inSeconds / 60.0;

    // 4. Apply flagging logic
    bool isFlagged = false;
    String? flagReason;

    final flagResult = _computeFlags(
      studioType: activeSession.studioType ?? studio.studioType,
      durationMinutes: durationMinutes,
    );
    isFlagged = flagResult.isFlagged;
    flagReason = flagResult.reason;

    // 5. Update local session
    final completedSession = activeSession.copyWith(
      status: CleaningSessionStatus.completed,
      completedAt: now,
      durationMinutes: durationMinutes,
      isFlagged: isFlagged,
      flagReason: flagReason,
      syncStatus: SyncStatus.pending,
    );
    await _localDb.updateCleaningSession(completedSession);

    // 6. Attempt Supabase RPC scan_out
    String? warning;
    try {
      final response =
          await _supabase.rpc<Map<String, dynamic>>('scan_out', params: {
        'p_employee_id': employeeId,
        'p_qr_code': qrCode,
      });

      if (response['success'] == true) {
        await _localDb.markCleaningSessionSynced(activeSession.id);
        if (response['is_flagged'] == true) {
          warning = _flagWarningMessage(
            activeSession.studioType ?? studio.studioType,
            durationMinutes,
          );
        }
        return ScanResult.success(
          completedSession.copyWith(syncStatus: SyncStatus.synced),
          warning: warning,
        );
      }
    } catch (_) {
      // Network error - session is pending sync
    }

    if (isFlagged) {
      warning = _flagWarningMessage(
        activeSession.studioType ?? studio.studioType,
        durationMinutes,
      );
    }
    return ScanResult.success(completedSession, warning: warning);
  }

  /// Auto-close all open sessions when shift ends.
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

      final flagResult = _computeFlags(
        studioType: session.studioType ?? StudioType.unit,
        durationMinutes: durationMinutes,
      );

      final closedSession = session.copyWith(
        status: CleaningSessionStatus.autoClosed,
        completedAt: closedAt,
        durationMinutes: durationMinutes,
        isFlagged: flagResult.isFlagged,
        flagReason: flagResult.reason,
        syncStatus: SyncStatus.pending,
      );
      await _localDb.updateCleaningSession(closedSession);
    }

    // Attempt Supabase sync
    try {
      await _supabase.rpc('auto_close_shift_sessions', params: {
        'p_shift_id': shiftId,
        'p_employee_id': employeeId,
        'p_closed_at': closedAt.toIso8601String(),
      });

      // Mark all as synced
      for (final session in sessions) {
        await _localDb.markCleaningSessionSynced(session.id);
      }
    } catch (_) {
      // Will be synced later
    }

    return sessions.length;
  }

  /// Get the current active cleaning session for the employee.
  Future<CleaningSession?> getActiveSession(String employeeId) async {
    return _localDb.getActiveSessionForEmployee(employeeId);
  }

  /// Get all cleaning sessions for a shift.
  Future<List<CleaningSession>> getShiftSessions(String shiftId) async {
    return _localDb.getSessionsForShift(shiftId);
  }

  /// Sync all pending local sessions to Supabase.
  Future<void> syncPendingSessions(String employeeId) async {
    final pending = await _localDb.getPendingCleaningSessions(employeeId);

    for (final session in pending) {
      try {
        if (session.status == CleaningSessionStatus.inProgress) {
          // Sync scan-in
          final studio = await _localDb.getStudioByQrCode('');
          // We need the QR code but don't have it in the session.
          // Use the Supabase direct insert as fallback.
          final response =
              await _supabase.rpc<Map<String, dynamic>>('scan_in', params: {
            'p_employee_id': session.employeeId,
            'p_qr_code': await _getQrCodeForStudio(session.studioId),
            'p_shift_id': session.shiftId,
          });

          if (response['success'] == true) {
            await _localDb.markCleaningSessionSynced(session.id,
                serverId: response['session_id'] as String?);
          } else {
            await _localDb.markCleaningSessionSyncError(session.id);
          }
        } else {
          // Completed/auto-closed/manually-closed: sync scan-out
          final qrCode = await _getQrCodeForStudio(session.studioId);
          final response =
              await _supabase.rpc<Map<String, dynamic>>('scan_out', params: {
            'p_employee_id': session.employeeId,
            'p_qr_code': qrCode,
          });

          if (response['success'] == true) {
            await _localDb.markCleaningSessionSynced(session.id);
          } else {
            await _localDb.markCleaningSessionSyncError(session.id);
          }
        }
      } catch (_) {
        await _localDb.markCleaningSessionSyncError(session.id);
      }
    }
  }

  /// Helper: get QR code for a studio ID from local cache.
  Future<String> _getQrCodeForStudio(String studioId) async {
    final studios = await _localDb.getAllStudios();
    final match = studios.where((s) => s.id == studioId).firstOrNull;
    return match?.qrCode ?? '';
  }

  /// Compute flagging based on studio type and duration.
  _FlagResult _computeFlags({
    required StudioType studioType,
    required double durationMinutes,
  }) {
    if (durationMinutes > 240) {
      return _FlagResult(true, 'Durée excessive (>${_formatDuration(240)})');
    }

    switch (studioType) {
      case StudioType.unit:
        if (durationMinutes < 5) {
          return _FlagResult(true, 'Durée trop courte pour une unité (<5 min)');
        }
      case StudioType.commonArea:
      case StudioType.conciergerie:
        if (durationMinutes < 2) {
          return _FlagResult(true, 'Durée trop courte (<2 min)');
        }
    }

    return _FlagResult(false, null);
  }

  /// Generate a user-facing warning message for flagged sessions.
  String _flagWarningMessage(StudioType studioType, double durationMinutes) {
    if (durationMinutes > 240) {
      return 'Durée exceptionnellement longue (${_formatDuration(durationMinutes.round())})';
    }
    if (studioType == StudioType.unit && durationMinutes < 5) {
      return 'Durée inhabituellement courte pour une unité';
    }
    if (durationMinutes < 2) {
      return 'Durée inhabituellement courte';
    }
    return 'Session signalée';
  }

  String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h > 0) return '${h}h ${m}min';
    return '${m} min';
  }
}

class _FlagResult {
  final bool isFlagged;
  final String? reason;
  _FlagResult(this.isFlagged, this.reason);
}
