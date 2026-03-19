import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../cleaning/services/studio_cache_service.dart';
import '../../maintenance/providers/maintenance_provider.dart';
import '../../maintenance/services/property_cache_service.dart';
import '../../shifts/providers/connectivity_provider.dart';
import '../../shifts/providers/location_provider.dart';
import '../../shifts/providers/shift_provider.dart';
import '../../tracking/providers/gps_health_guard_provider.dart';
import '../models/activity_type.dart';
import '../models/work_session.dart';
import '../services/work_session_local_db.dart';
import '../services/work_session_service.dart';

// ============ DEPENDENCY PROVIDERS ============

/// Provider for WorkSessionLocalDb instance.
final workSessionLocalDbProvider = Provider<WorkSessionLocalDb>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return WorkSessionLocalDb(localDb);
});

/// Provider for WorkSessionService.
///
/// Imports [studioCacheServiceProvider] from cleaning and
/// [propertyCacheServiceProvider] from maintenance (Phase 1 compatibility).
final workSessionServiceProvider = Provider<WorkSessionService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final localDb = ref.watch(workSessionLocalDbProvider);
  final studioCache = ref.watch(studioCacheServiceProvider);
  final propertyCache = ref.watch(propertyCacheServiceProvider);
  return WorkSessionService(supabase, localDb, studioCache, propertyCache);
});

// ============ STATE ============

/// State for work session operations.
class WorkSessionState {
  final WorkSession? activeSession;
  final bool isScanning;
  final bool isLoading;
  final String? error;
  final bool isInitialized;

  const WorkSessionState({
    this.activeSession,
    this.isScanning = false,
    this.isLoading = false,
    this.error,
    this.isInitialized = false,
  });

  WorkSessionState copyWith({
    WorkSession? activeSession,
    bool? isScanning,
    bool? isLoading,
    String? error,
    bool? isInitialized,
    bool clearActiveSession = false,
    bool clearError = false,
  }) {
    return WorkSessionState(
      activeSession:
          clearActiveSession ? null : (activeSession ?? this.activeSession),
      isScanning: isScanning ?? this.isScanning,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

// ============ NOTIFIER ============

/// Notifier for managing unified work session state.
///
/// Combines the patterns from [CleaningSessionNotifier] and
/// [MaintenanceSessionNotifier] into a single notifier that handles
/// cleaning, maintenance, and admin activity types.
class WorkSessionNotifier extends StateNotifier<WorkSessionState> {
  final WorkSessionService _service;
  final StudioCacheService _studioCache;
  final PropertyCacheService _propertyCache;
  final String? _employeeId;
  final Ref _ref;
  StreamSubscription<bool>? _connectivitySub;

  WorkSessionNotifier(
    this._service,
    this._studioCache,
    this._propertyCache,
    this._employeeId,
    this._ref,
  ) : super(const WorkSessionState()) {
    if (_employeeId != null) {
      _initialize();
    }
  }

  // ============ INITIALIZATION ============

  /// Initialize: sync caches, load active session, listen for connectivity.
  Future<void> _initialize() async {
    // Sync studio + property caches in background (non-blocking)
    _syncStudioCacheQuietly();
    _syncPropertyCacheQuietly();

    // Load active session from local storage
    await loadActiveSession();

    // Listen for connectivity changes to trigger pending session sync
    _listenToConnectivity();

    // Sync any pending sessions from previous runs
    _syncPendingQuietly();

    state = state.copyWith(isInitialized: true);
  }

  /// Sync studio cache in background (non-blocking).
  Future<void> _syncStudioCacheQuietly() async {
    try {
      await _studioCache.syncStudios();
    } catch (_) {
      // Offline or error: use cached data
    }
  }

  /// Sync property cache in background (non-blocking).
  Future<void> _syncPropertyCacheQuietly() async {
    try {
      await _propertyCache.syncProperties();
    } catch (_) {
      // Offline or error: use cached data
    }
  }

  /// Listen to connectivity changes and sync pending sessions when online.
  void _listenToConnectivity() {
    _connectivitySub = _ref
        .read(connectivityServiceProvider)
        .onConnectivityChanged
        .listen((isConnected) {
      if (isConnected && _employeeId != null) {
        _syncPendingQuietly();
      }
    });
  }

  /// Sync pending work sessions in background (non-blocking).
  Future<void> _syncPendingQuietly() async {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    try {
      await _service.syncPendingSessions(employeeId);
    } catch (_) {
      // Will retry on next connectivity change
    }
  }

  // ============ PUBLIC METHODS ============

  /// Trigger pending sync (callable from app resume or pull-to-refresh).
  Future<void> syncPending() async {
    await _syncPendingQuietly();
  }

  /// Load active work session from local storage.
  Future<void> loadActiveSession() async {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    try {
      final session = await _service.getActiveSession(employeeId);
      state = state.copyWith(
        activeSession: session,
        clearActiveSession: session == null,
      );
    } catch (e) {
      state = state.copyWith(error: 'Erreur de chargement de la session');
    }
  }

  /// Start a new work session.
  ///
  /// GPS health gate is enforced before capturing the location.
  /// For cleaning: pass [qrCode] or [studioId] to identify the studio.
  /// For maintenance: pass [buildingId] + optional [apartmentId].
  /// For admin: no location params required.
  Future<WorkSessionResult> startSession({
    required String shiftId,
    required ActivityType activityType,
    String? qrCode,
    String? studioId,
    String? buildingId,
    String? buildingName,
    String? apartmentId,
    String? unitNumber,
    String? serverShiftId,
  }) async {
    // Hard-gate GPS health check — restart if dead
    await ensureGpsAlive(_ref, source: 'work_session_start');

    final employeeId = _employeeId;
    if (employeeId == null) {
      return WorkSessionResult.error(
        'NO_AUTH',
        errorMessage: 'Non authentifié',
      );
    }

    state = state.copyWith(isScanning: true, isLoading: true, clearError: true);

    try {
      // Capture GPS position at session start
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.startSession(
        employeeId: employeeId,
        shiftId: shiftId,
        activityType: activityType,
        qrCode: qrCode,
        studioId: studioId,
        buildingId: buildingId,
        buildingName: buildingName,
        apartmentId: apartmentId,
        unitNumber: unitNumber,
        serverShiftId: serverShiftId,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
      );

      if (result.success && result.session != null) {
        state = state.copyWith(
          activeSession: result.session,
          isScanning: false,
          isLoading: false,
        );
        // Update Live Activity with session info
        ShiftActivityService.instance.updateSessionInfo(
          sessionType: result.session!.activityType.toJson(),
          sessionLocation: result.session!.locationLabel,
          sessionStartedAt: result.session!.startedAt,
        );
      } else {
        state = state.copyWith(
          isScanning: false,
          isLoading: false,
          error: result.errorMessage,
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        isLoading: false,
        error: 'Erreur lors du démarrage: $e',
      );
      return WorkSessionResult.error(
        'UNEXPECTED',
        errorMessage: 'Erreur inattendue',
      );
    }
  }

  /// Complete the active work session.
  ///
  /// GPS health gate is enforced before capturing the location.
  /// For cleaning: pass [qrCode] to validate scan-out matches current studio.
  /// For maintenance/admin: no qrCode needed.
  Future<WorkSessionResult> completeSession({String? qrCode}) async {
    // Hard-gate GPS health check — restart if dead
    await ensureGpsAlive(_ref, source: 'work_session_complete');

    final employeeId = _employeeId;
    if (employeeId == null) {
      return WorkSessionResult.error(
        'NO_AUTH',
        errorMessage: 'Non authentifié',
      );
    }

    state = state.copyWith(isScanning: true, isLoading: true, clearError: true);

    try {
      // Capture GPS position at session end
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.completeSession(
        employeeId: employeeId,
        qrCode: qrCode,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
      );

      if (result.success) {
        state = state.copyWith(
          isScanning: false,
          isLoading: false,
          clearActiveSession: true,
        );
        // Clear session info from Live Activity
        ShiftActivityService.instance.updateSessionInfo();
      } else {
        state = state.copyWith(
          isScanning: false,
          isLoading: false,
          error: result.errorMessage,
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        isLoading: false,
        error: 'Erreur lors de la complétion: $e',
      );
      return WorkSessionResult.error(
        'UNEXPECTED',
        errorMessage: 'Erreur inattendue',
      );
    }
  }

  /// Manually close the active work session (without scanning/completing).
  Future<bool> manualClose() async {
    final employeeId = _employeeId;
    if (employeeId == null) return false;

    state = state.copyWith(clearError: true);

    try {
      final result = await _service.manualClose(employeeId: employeeId);
      if (result != null) {
        state = state.copyWith(clearActiveSession: true);
        ShiftActivityService.instance.updateSessionInfo();
        return true;
      }
      state = state.copyWith(error: 'Aucune session active');
      return false;
    } catch (e) {
      state = state.copyWith(error: 'Erreur lors de la fermeture: $e');
      return false;
    }
  }

  /// Convenience wrapper: scan in for a cleaning session.
  ///
  /// Equivalent to [startSession] with activityType=cleaning.
  Future<WorkSessionResult> scanIn(
    String qrCode,
    String shiftId, {
    String? serverShiftId,
  }) {
    return startSession(
      shiftId: shiftId,
      activityType: ActivityType.cleaning,
      qrCode: qrCode,
      serverShiftId: serverShiftId,
    );
  }

  /// Convenience wrapper: scan out for a cleaning session.
  ///
  /// Equivalent to [completeSession] with qrCode validation.
  Future<WorkSessionResult> scanOut(String qrCode) {
    return completeSession(qrCode: qrCode);
  }

  /// Change activity type: completes the current session and returns.
  ///
  /// The caller is responsible for opening the activity type picker after
  /// this method completes and starting a new session with the selected type.
  Future<bool> changeActivityType() async {
    final employeeId = _employeeId;
    if (employeeId == null) return false;

    if (state.activeSession == null) return true; // No active session to close

    // Complete current session first
    final result = await completeSession();
    return result.success;
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}

// ============ PROVIDERS ============

/// Provider for work session state management.
final workSessionProvider =
    StateNotifierProvider<WorkSessionNotifier, WorkSessionState>((ref) {
  final service = ref.watch(workSessionServiceProvider);
  final studioCache = ref.watch(studioCacheServiceProvider);
  final propertyCache = ref.watch(propertyCacheServiceProvider);
  final user = ref.watch(currentUserProvider);
  return WorkSessionNotifier(service, studioCache, propertyCache, user?.id, ref);
});

// ============ DERIVED PROVIDERS ============

/// Provider for checking if employee has an active work session.
final hasActiveWorkSessionProvider = Provider<bool>((ref) {
  return ref.watch(workSessionProvider).activeSession != null;
});

/// Provider for the active work session.
final activeWorkSessionProvider = Provider<WorkSession?>((ref) {
  return ref.watch(workSessionProvider).activeSession;
});

/// Provider for work sessions in a specific shift.
final shiftWorkSessionsProvider =
    FutureProvider.family<List<WorkSession>, String>((ref, shiftId) async {
  final service = ref.watch(workSessionServiceProvider);
  // Invalidate when active session changes (new start/complete)
  ref.watch(workSessionProvider);
  return service.getShiftSessions(shiftId);
});

/// Provider for work sessions across all segments of a lunch-split shift group.
/// Uses workBodyId to find all sibling shift IDs, then queries sessions for all.
/// Falls back to single shift if no workBodyId.
final shiftGroupWorkSessionsProvider =
    FutureProvider<List<WorkSession>>((ref) async {
  final shiftState = ref.watch(shiftProvider);
  ref.watch(workSessionProvider); // Invalidate on session changes
  final shift = shiftState.activeShift;
  if (shift == null) return [];

  final service = ref.watch(workSessionServiceProvider);

  if (shift.workBodyId != null) {
    final localDb = ref.watch(localDatabaseProvider);
    final siblingIds = await localDb.getShiftIdsByWorkBodyId(shift.workBodyId!);
    if (siblingIds.isNotEmpty) {
      return service.getShiftGroupSessions(siblingIds);
    }
  }
  return service.getShiftSessions(shift.id);
});

/// Provider for the last activity type used in the current shift.
/// Returns null if no sessions have been completed yet in this shift.
final lastActivityTypeProvider = FutureProvider<ActivityType?>((ref) async {
  final shiftState = ref.watch(shiftProvider);
  ref.watch(workSessionProvider); // Invalidate when session state changes
  final shift = shiftState.activeShift;
  if (shift == null) return null;

  final localDb = ref.watch(workSessionLocalDbProvider);
  final typeStr = await localDb.getLastActivityTypeForShift(shift.id);
  if (typeStr == null) return null;
  return ActivityType.fromJson(typeStr);
});
