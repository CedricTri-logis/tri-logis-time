import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../cleaning/models/studio.dart';
import '../../cleaning/services/studio_cache_service.dart';
import '../../maintenance/services/property_cache_service.dart';
import '../../shifts/models/shift_enums.dart';
import '../models/activity_type.dart';
import '../models/work_session.dart';
import 'work_session_local_db.dart';

/// Unified service for work session lifecycle with local-first architecture.
///
/// Consolidates logic from [CleaningSessionService] and
/// [MaintenanceSessionService] into a single service that handles
/// cleaning, maintenance, and admin activity types.
class WorkSessionService {
  final SupabaseClient _supabase;
  final WorkSessionLocalDb _localDb;
  final StudioCacheService _studioCache;

  // ignore: unused_field
  final PropertyCacheService _propertyCache;
  final Uuid _uuid;

  WorkSessionService(
    this._supabase,
    this._localDb,
    this._studioCache,
    this._propertyCache,
  ) : _uuid = const Uuid();

  // ============ START SESSION ============

  /// Start a work session (unified replacement for scanIn + startMaintenanceSession).
  ///
  /// For cleaning: pass [qrCode] or [studioId] to identify the studio.
  /// For maintenance: pass [buildingId] + optional [apartmentId].
  /// For admin: no location params required.
  Future<WorkSessionResult> startSession({
    required String employeeId,
    required String shiftId,
    required ActivityType activityType,
    // Cleaning params
    String? qrCode,
    String? studioId,
    // Maintenance params
    String? buildingId,
    String? buildingName,
    String? apartmentId,
    String? unitNumber,
    // Server shift
    String? serverShiftId,
    // GPS
    double? latitude,
    double? longitude,
    double? accuracy,
  }) async {
    Studio? studio;

    // 1. If cleaning + qrCode, look up studio in cache (same as existing scanIn)
    if (activityType == ActivityType.cleaning && qrCode != null) {
      studio = await _studioCache.lookupByQrCode(qrCode);

      // If not found locally, try Supabase lookup and update cache
      if (studio == null) {
        try {
          final response = await _supabase
              .from('studios')
              .select(
                'id, qr_code, studio_number, building_id, studio_type, is_active, buildings!inner(name)',
              )
              .eq('qr_code', qrCode)
              .maybeSingle();

          if (response != null) {
            final bName =
                response['buildings']?['name'] as String? ?? '';
            studio = Studio(
              id: response['id'] as String,
              qrCode: response['qr_code'] as String,
              studioNumber: response['studio_number'] as String,
              buildingId: response['building_id'] as String,
              buildingName: bName,
              studioType: StudioType.fromJson(
                response['studio_type'] as String? ?? 'unit',
              ),
              isActive: response['is_active'] as bool? ?? true,
            );
            // Note: studio cache is managed by StudioCacheService.syncStudios()
            // The next sync will pick up this studio.
          }
        } catch (_) {
          // Network error - studio not in cache and offline
        }
      }

      // If still not found -> INVALID_QR
      if (studio == null) {
        return WorkSessionResult.error(
          'INVALID_QR',
          errorMessage: 'Code QR non reconnu',
        );
      }

      // Check if studio is active
      if (!studio.isActive) {
        return WorkSessionResult.error(
          'STUDIO_INACTIVE',
          errorMessage: 'Ce studio n\'est plus actif',
        );
      }

      // Use studio info for the session
      studioId = studio.id;
      buildingId = studio.buildingId;
      buildingName = studio.buildingName;
    }

    // 2. Auto-close any active work session (local)
    final existingSession =
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (existingSession != null) {
      // Check for double-tap on same location
      if (_isSameLocation(
        existingSession,
        activityType,
        studioId: studioId,
        buildingId: buildingId,
        apartmentId: apartmentId,
      )) {
        return WorkSessionResult.success(existingSession);
      }
      // Different location — auto-close previous
      await _closeSession(existingSession, WorkSessionStatus.manuallyClosed);
    }

    // 3. Create local work_session with UUID
    final sessionId = _uuid.v4();
    final now = DateTime.now().toUtc();

    final session = WorkSession(
      id: sessionId,
      employeeId: employeeId,
      shiftId: shiftId,
      activityType: activityType,
      locationType: _resolveLocationType(
        activityType,
        studioId: studioId,
        buildingId: buildingId,
        apartmentId: apartmentId,
      ),
      status: WorkSessionStatus.inProgress,
      startedAt: now,
      syncStatus: SyncStatus.pending,
      studioId: studioId,
      buildingId: buildingId,
      apartmentId: apartmentId,
      buildingName: buildingName,
      studioNumber: studio?.studioNumber,
      unitNumber: unitNumber,
      studioType: studio?.studioType.toJson(),
      startLatitude: latitude,
      startLongitude: longitude,
      startAccuracy: accuracy,
    );

    await _localDb.insertWorkSession(session);

    // 4. Resolve server shift ID (retry loop — follow exact pattern from cleaning service)
    var resolvedShiftId = serverShiftId;
    if (resolvedShiftId == null) {
      for (var attempt = 0; attempt < 5; attempt++) {
        resolvedShiftId = await _localDb.resolveServerShiftId(shiftId);
        if (resolvedShiftId != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    // Last resort: query server directly for employee's active shift
    if (resolvedShiftId == null) {
      try {
        final serverShift = await _supabase
            .from('shifts')
            .select('id')
            .eq('employee_id', employeeId)
            .eq('status', 'active')
            .maybeSingle();
        if (serverShift != null) {
          resolvedShiftId = serverShift['id'] as String;
        }
      } catch (_) {
        // Server unreachable — fall through to error
      }
    }

    if (resolvedShiftId == null) {
      // Server shift not synced — cannot start session without server confirmation
      // Delete the local session since we're not going through with it
      await _localDb.deleteWorkSession(sessionId);
      return WorkSessionResult.error(
        'NO_SERVER_SHIFT',
        errorMessage:
            'Connexion requise. Vérifiez votre connexion réseau et réessayez.',
      );
    }

    // 5. Call RPC start_work_session with all params
    try {
      final params = <String, dynamic>{
        'p_employee_id': employeeId,
        'p_shift_id': resolvedShiftId,
        'p_activity_type': activityType.toJson(),
      };
      if (qrCode != null) params['p_qr_code'] = qrCode;
      if (studioId != null) params['p_studio_id'] = studioId;
      if (buildingId != null) params['p_building_id'] = buildingId;
      if (apartmentId != null) params['p_apartment_id'] = apartmentId;
      if (latitude != null) params['p_latitude'] = latitude;
      if (longitude != null) params['p_longitude'] = longitude;
      if (accuracy != null) params['p_accuracy'] = accuracy;

      final response = await _supabase
          .rpc<Map<String, dynamic>>('start_work_session', params: params);

      if (response['success'] == true) {
        // 6. On success: mark synced
        final serverId = response['session_id'] as String?;
        if (serverId != null) {
          await _localDb.markWorkSessionSynced(
            sessionId,
            serverId: serverId,
          );
        }
        return WorkSessionResult.success(
          session.copyWith(syncStatus: SyncStatus.synced),
        );
      } else {
        // Server rejected — delete local session and return error
        final errorCode =
            response['error'] as String? ?? 'SERVER_REJECTED';
        await _localDb.deleteWorkSession(sessionId);
        return WorkSessionResult.error(
          errorCode,
          errorMessage: _humanReadableError(errorCode),
        );
      }
    } catch (e) {
      // Network/server error — delete local session and return error
      await _localDb.deleteWorkSession(sessionId);
      return WorkSessionResult.error(
        'NETWORK_ERROR',
        errorMessage:
            'Connexion requise. Vérifiez votre connexion réseau et réessayez.',
      );
    }
  }

  // ============ COMPLETE SESSION ============

  /// Complete the active work session (unified replacement for scanOut + completeMaintenanceSession).
  ///
  /// For cleaning: pass [qrCode] to validate scan-out matches current studio.
  /// For maintenance/admin: no qrCode needed.
  Future<WorkSessionResult> completeSession({
    required String employeeId,
    String? qrCode,
    double? latitude,
    double? longitude,
    double? accuracy,
  }) async {
    // 1. Find active local session
    final activeSession =
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (activeSession == null) {
      return WorkSessionResult.error(
        'NO_ACTIVE_SESSION',
        errorMessage: 'Aucune session active',
      );
    }

    // 2. If cleaning + qrCode, validate QR matches current studio
    if (activeSession.activityType == ActivityType.cleaning &&
        qrCode != null) {
      final studio = await _studioCache.lookupByQrCode(qrCode);
      if (studio == null) {
        return WorkSessionResult.error(
          'INVALID_QR',
          errorMessage: 'Code QR non reconnu',
        );
      }
      if (studio.id != activeSession.studioId) {
        return WorkSessionResult.error(
          'QR_MISMATCH',
          errorMessage:
              'Ce code QR ne correspond pas au studio en cours',
        );
      }
    }

    // 3. Compute duration + flags (cleaning only, same logic as existing)
    final now = DateTime.now().toUtc();
    final durationMinutes =
        now.difference(activeSession.startedAt).inSeconds / 60.0;

    bool isFlagged = false;
    String? flagReason;
    String? warning;

    if (activeSession.activityType == ActivityType.cleaning) {
      final studioType = activeSession.studioType != null
          ? StudioType.fromJson(activeSession.studioType!)
          : StudioType.unit;
      final flagResult = _computeFlags(
        studioType: studioType,
        durationMinutes: durationMinutes,
      );
      isFlagged = flagResult.isFlagged;
      flagReason = flagResult.reason;
      if (isFlagged) {
        warning = _flagWarningMessage(studioType, durationMinutes);
      }
    }

    // 4. Update local session to completed
    final completedSession = activeSession.copyWith(
      status: WorkSessionStatus.completed,
      completedAt: now,
      durationMinutes: durationMinutes,
      isFlagged: isFlagged,
      flagReason: flagReason,
      syncStatus: SyncStatus.pending,
      endLatitude: latitude,
      endLongitude: longitude,
      endAccuracy: accuracy,
    );
    await _localDb.updateWorkSession(completedSession);

    // 5. Call RPC complete_work_session
    try {
      final params = <String, dynamic>{
        'p_employee_id': employeeId,
      };
      if (activeSession.serverId != null) {
        params['p_session_id'] = activeSession.serverId;
      }
      if (qrCode != null) params['p_qr_code'] = qrCode;
      if (latitude != null) params['p_latitude'] = latitude;
      if (longitude != null) params['p_longitude'] = longitude;
      if (accuracy != null) params['p_accuracy'] = accuracy;

      final response = await _supabase
          .rpc<Map<String, dynamic>>(
        'complete_work_session',
        params: params,
      );

      if (response['success'] == true) {
        await _localDb.markWorkSessionSynced(activeSession.id);
        // Check if server flagged it
        if (response['is_flagged'] == true &&
            activeSession.activityType == ActivityType.cleaning) {
          final studioType = activeSession.studioType != null
              ? StudioType.fromJson(activeSession.studioType!)
              : StudioType.unit;
          warning = _flagWarningMessage(studioType, durationMinutes);
        }
        return WorkSessionResult.success(
          completedSession.copyWith(syncStatus: SyncStatus.synced),
          warning: warning,
        );
      }
    } catch (e) {
      // Network error — revert local status back to in_progress
      await _localDb.updateWorkSessionStatus(
        activeSession.id,
        WorkSessionStatus.inProgress,
      );
      return WorkSessionResult.error(
        'NETWORK_ERROR',
        errorMessage:
            'Connexion requise pour terminer la session. Vérifiez votre connexion réseau.',
      );
    }

    // 6. Return result (RPC returned non-success but no exception)
    return WorkSessionResult.success(completedSession, warning: warning);
  }

  // ============ MANUAL CLOSE ============

  /// Manually close a specific session (or the active one).
  Future<WorkSession?> manualClose({
    required String employeeId,
    String? sessionId,
  }) async {
    WorkSession? activeSession;
    if (sessionId != null) {
      // Find the specific session via shift sessions
      final sessions =
          await _localDb.getPendingWorkSessions(employeeId);
      activeSession =
          sessions.where((s) => s.id == sessionId).firstOrNull;
    }
    activeSession ??=
        await _localDb.getActiveSessionForEmployee(employeeId);
    if (activeSession == null) return null;

    final now = DateTime.now().toUtc();
    final durationMinutes =
        now.difference(activeSession.startedAt).inSeconds / 60.0;

    // Compute flags for cleaning sessions
    bool isFlagged = false;
    String? flagReason;
    if (activeSession.activityType == ActivityType.cleaning) {
      final studioType = activeSession.studioType != null
          ? StudioType.fromJson(activeSession.studioType!)
          : StudioType.unit;
      final flagResult = _computeFlags(
        studioType: studioType,
        durationMinutes: durationMinutes,
      );
      isFlagged = flagResult.isFlagged;
      flagReason = flagResult.reason;
    }

    final closedSession = activeSession.copyWith(
      status: WorkSessionStatus.manuallyClosed,
      completedAt: now,
      durationMinutes: durationMinutes,
      isFlagged: isFlagged,
      flagReason: flagReason,
      syncStatus: SyncStatus.pending,
    );
    await _localDb.updateWorkSession(closedSession);

    // Try to sync to Supabase
    try {
      await _supabase.rpc<Map<String, dynamic>>(
        'manually_close_work_session',
        params: {
          'p_employee_id': employeeId,
          'p_session_id': activeSession.id,
          'p_closed_at': now.toIso8601String(),
        },
      );
      await _localDb.markWorkSessionSynced(activeSession.id);
      return closedSession.copyWith(syncStatus: SyncStatus.synced);
    } catch (_) {
      // Will be synced later
      return closedSession;
    }
  }

  // ============ AUTO-CLOSE ============

  /// Auto-close all in-progress sessions for a shift.
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

      // Compute flags for cleaning sessions
      bool isFlagged = false;
      String? flagReason;
      if (session.activityType == ActivityType.cleaning) {
        final studioType = session.studioType != null
            ? StudioType.fromJson(session.studioType!)
            : StudioType.unit;
        final flagResult = _computeFlags(
          studioType: studioType,
          durationMinutes: durationMinutes,
        );
        isFlagged = flagResult.isFlagged;
        flagReason = flagResult.reason;
      }

      final closedSession = session.copyWith(
        status: WorkSessionStatus.autoClosed,
        completedAt: closedAt,
        durationMinutes: durationMinutes,
        isFlagged: isFlagged,
        flagReason: flagReason,
        syncStatus: SyncStatus.pending,
      );
      await _localDb.updateWorkSession(closedSession);
    }

    // Attempt Supabase sync — resolve server shift ID
    try {
      final serverShiftId = await _localDb.resolveServerShiftId(shiftId);
      if (serverShiftId != null) {
        await _supabase.rpc<Map<String, dynamic>>(
          'auto_close_work_sessions',
          params: {
            'p_shift_id': serverShiftId,
            'p_employee_id': employeeId,
            'p_closed_at': closedAt.toIso8601String(),
          },
        );

        // Mark all as synced
        for (final session in sessions) {
          await _localDb.markWorkSessionSynced(session.id);
        }
      }
    } catch (_) {
      // Will be synced later
    }

    return sessions.length;
  }

  // ============ GETTERS ============

  /// Get the current active work session for the employee.
  Future<WorkSession?> getActiveSession(String employeeId) async {
    return _localDb.getActiveSessionForEmployee(employeeId);
  }

  /// Get all work sessions for a shift.
  Future<List<WorkSession>> getShiftSessions(String shiftId) async {
    return _localDb.getSessionsForShift(shiftId);
  }

  /// Get count of pending work sessions for an employee.
  Future<int> getPendingCount(String employeeId) async {
    return _localDb.getPendingWorkSessionCount(employeeId);
  }

  // ============ SYNC ============

  /// Sync all pending work sessions to Supabase.
  ///
  /// Uses the same retry pattern as the cleaning service:
  /// - In-progress sessions: call start RPC with correct server shift ID
  /// - Completed/closed sessions: direct insert into work_sessions table
  Future<void> syncPendingSessions(String employeeId) async {
    final pending = await _localDb.getPendingWorkSessions(employeeId);

    for (final session in pending) {
      try {
        // Resolve the server shift ID from local DB
        final serverShiftId =
            await _localDb.resolveServerShiftId(session.shiftId);
        if (serverShiftId == null) {
          // Shift not synced yet — skip, will retry later
          continue;
        }

        if (session.status == WorkSessionStatus.inProgress) {
          // Sync in-progress session via RPC with correct server shift ID
          final params = <String, dynamic>{
            'p_employee_id': session.employeeId,
            'p_shift_id': serverShiftId,
            'p_activity_type': session.activityType.toJson(),
          };

          // Add location params based on activity type
          if (session.activityType == ActivityType.cleaning &&
              session.studioId != null) {
            final qrCode =
                await _getQrCodeForStudio(session.studioId!);
            if (qrCode.isNotEmpty) params['p_qr_code'] = qrCode;
            params['p_studio_id'] = session.studioId;
          }
          if (session.buildingId != null) {
            params['p_building_id'] = session.buildingId;
          }
          if (session.apartmentId != null) {
            params['p_apartment_id'] = session.apartmentId;
          }
          if (session.startLatitude != null) {
            params['p_latitude'] = session.startLatitude;
          }
          if (session.startLongitude != null) {
            params['p_longitude'] = session.startLongitude;
          }
          if (session.startAccuracy != null) {
            params['p_accuracy'] = session.startAccuracy;
          }

          final response = await _supabase
              .rpc<Map<String, dynamic>>(
            'start_work_session',
            params: params,
          );

          if (response['success'] == true) {
            await _localDb.markWorkSessionSynced(
              session.id,
              serverId: response['session_id'] as String?,
            );
          } else {
            await _localDb.markWorkSessionSyncError(session.id);
          }
        } else {
          // Completed/auto-closed/manually-closed: direct insert
          // RPCs won't work because start RPC never succeeded and shift may
          // no longer be active. Insert the full record directly.
          final insertData = <String, dynamic>{
            'employee_id': session.employeeId,
            'shift_id': serverShiftId,
            'activity_type': session.activityType.toJson(),
            'status': session.status.toJson(),
            'started_at': session.startedAt.toUtc().toIso8601String(),
            'completed_at':
                session.completedAt?.toUtc().toIso8601String(),
            'duration_minutes': session.durationMinutes,
            'is_flagged': session.isFlagged,
            'flag_reason': session.flagReason,
          };

          // Location fields
          if (session.studioId != null) {
            insertData['studio_id'] = session.studioId;
          }
          if (session.buildingId != null) {
            insertData['building_id'] = session.buildingId;
          }
          if (session.apartmentId != null) {
            insertData['apartment_id'] = session.apartmentId;
          }
          if (session.notes != null) {
            insertData['notes'] = session.notes;
          }

          // GPS fields
          if (session.startLatitude != null) {
            insertData['start_latitude'] = session.startLatitude;
          }
          if (session.startLongitude != null) {
            insertData['start_longitude'] = session.startLongitude;
          }
          if (session.startAccuracy != null) {
            insertData['start_accuracy'] = session.startAccuracy;
          }
          if (session.endLatitude != null) {
            insertData['end_latitude'] = session.endLatitude;
          }
          if (session.endLongitude != null) {
            insertData['end_longitude'] = session.endLongitude;
          }
          if (session.endAccuracy != null) {
            insertData['end_accuracy'] = session.endAccuracy;
          }

          final response = await _supabase
              .from('work_sessions')
              .insert(insertData)
              .select('id')
              .single();

          await _localDb.markWorkSessionSynced(
            session.id,
            serverId: response['id'] as String?,
          );
        }
      } catch (_) {
        await _localDb.markWorkSessionSyncError(session.id);
      }
    }
  }

  // ============ PRIVATE HELPERS ============

  /// Close a session with the given status.
  Future<void> _closeSession(
    WorkSession session,
    WorkSessionStatus status,
  ) async {
    final now = DateTime.now().toUtc();
    final duration =
        now.difference(session.startedAt).inSeconds / 60.0;
    await _localDb.updateWorkSession(
      session.copyWith(
        status: status,
        completedAt: now,
        durationMinutes: double.parse(duration.toStringAsFixed(2)),
        syncStatus: SyncStatus.pending,
      ),
    );
  }

  /// Check if an existing session is for the same location (double-tap detection).
  bool _isSameLocation(
    WorkSession existing,
    ActivityType activityType, {
    String? studioId,
    String? buildingId,
    String? apartmentId,
  }) {
    if (existing.activityType != activityType) return false;

    switch (activityType) {
      case ActivityType.cleaning:
        return existing.studioId == studioId;
      case ActivityType.maintenance:
        return existing.buildingId == buildingId &&
            existing.apartmentId == apartmentId;
      case ActivityType.admin:
        // Admin sessions are always "same location" (no location)
        return true;
    }
  }

  /// Resolve the location_type based on activity type and available IDs.
  String? _resolveLocationType(
    ActivityType activityType, {
    String? studioId,
    String? buildingId,
    String? apartmentId,
  }) {
    switch (activityType) {
      case ActivityType.cleaning:
        // Court terme (QR studio) vs long terme (building/apartment)
        if (studioId != null) return 'studio';
        if (buildingId != null) return apartmentId != null ? 'apartment' : 'building';
        return 'studio'; // fallback
      case ActivityType.maintenance:
        return apartmentId != null ? 'apartment' : 'building';
      case ActivityType.admin:
        return 'office';
    }
  }

  /// Helper: get QR code for a studio ID from local cache.
  Future<String> _getQrCodeForStudio(String studioId) async {
    final studios = await _studioCache.getAllStudios();
    final match = studios.where((s) => s.id == studioId).firstOrNull;
    return match?.qrCode ?? '';
  }

  /// Compute flagging based on studio type and duration (cleaning only).
  _FlagResult _computeFlags({
    required StudioType studioType,
    required double durationMinutes,
  }) {
    if (durationMinutes > 240) {
      return _FlagResult(
        true,
        'Durée excessive (>${_formatDuration(240)})',
      );
    }

    switch (studioType) {
      case StudioType.unit:
        if (durationMinutes < 5) {
          return _FlagResult(
            true,
            'Durée trop courte pour une unité (<5 min)',
          );
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
    return '$m min';
  }

  /// Map server error codes to user-facing French messages.
  String _humanReadableError(String code) {
    switch (code) {
      case 'NO_ACTIVE_SHIFT':
        return 'Aucun quart actif trouvé';
      case 'INVALID_QR_CODE':
        return 'Code QR non reconnu';
      case 'STUDIO_INACTIVE':
        return "Ce studio n'est plus actif";
      case 'STUDIO_REQUIRED':
      case 'LOCATION_REQUIRED':
        return 'Emplacement requis pour cette session';
      case 'BUILDING_REQUIRED':
      case 'BUILDING_NOT_FOUND':
        return 'Immeuble non trouvé';
      case 'APARTMENT_NOT_FOUND':
        return 'Appartement non trouvé';
      case 'INVALID_ACTIVITY_TYPE':
        return "Type d'activité invalide";
      default:
        return 'Session refusée par le serveur ($code)';
    }
  }
}

class _FlagResult {
  final bool isFlagged;
  final String? reason;
  _FlagResult(this.isFlagged, this.reason);
}
