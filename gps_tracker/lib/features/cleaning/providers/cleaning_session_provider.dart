import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../shifts/providers/connectivity_provider.dart';
import '../../shifts/providers/location_provider.dart';
import '../../shifts/providers/shift_provider.dart';
import '../models/cleaning_session.dart';
import '../models/scan_result.dart';
import '../../maintenance/services/maintenance_local_db.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../services/cleaning_local_db.dart';
import '../services/cleaning_session_service.dart';
import '../services/studio_cache_service.dart';

/// Provider for CleaningLocalDb instance.
final cleaningLocalDbProvider = Provider<CleaningLocalDb>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return CleaningLocalDb(localDb);
});

/// Provider for StudioCacheService.
final studioCacheServiceProvider = Provider<StudioCacheService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final cleaningDb = ref.watch(cleaningLocalDbProvider);
  return StudioCacheService(supabase, cleaningDb);
});

/// Provider for MaintenanceLocalDb (used for cross-feature validation).
final _maintenanceLocalDbProvider = Provider<MaintenanceLocalDb>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return MaintenanceLocalDb(localDb);
});

/// Provider for CleaningSessionService.
final cleaningSessionServiceProvider = Provider<CleaningSessionService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final cleaningDb = ref.watch(cleaningLocalDbProvider);
  final studioCache = ref.watch(studioCacheServiceProvider);
  final maintenanceDb = ref.watch(_maintenanceLocalDbProvider);
  return CleaningSessionService(
    supabase,
    cleaningDb,
    studioCache,
    maintenanceLocalDb: maintenanceDb,
  );
});

/// State for cleaning session operations.
class CleaningSessionState {
  final CleaningSession? activeSession;
  final bool isScanning;
  final String? error;
  final bool isInitialized;

  const CleaningSessionState({
    this.activeSession,
    this.isScanning = false,
    this.error,
    this.isInitialized = false,
  });

  CleaningSessionState copyWith({
    CleaningSession? activeSession,
    bool? isScanning,
    String? error,
    bool? isInitialized,
    bool clearActiveSession = false,
    bool clearError = false,
  }) {
    return CleaningSessionState(
      activeSession:
          clearActiveSession ? null : (activeSession ?? this.activeSession),
      isScanning: isScanning ?? this.isScanning,
      error: clearError ? null : (error ?? this.error),
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

/// Notifier for managing cleaning session state.
class CleaningSessionNotifier extends StateNotifier<CleaningSessionState> {
  final CleaningSessionService _service;
  final StudioCacheService _studioCache;
  final String? _employeeId;
  final Ref _ref;
  StreamSubscription<bool>? _connectivitySub;

  CleaningSessionNotifier(
    this._service,
    this._studioCache,
    this._employeeId,
    this._ref,
  ) : super(const CleaningSessionState()) {
    if (_employeeId != null) {
      _initialize();
    }
  }

  /// Initialize: sync studio cache, load active session, listen for connectivity.
  Future<void> _initialize() async {
    // Sync studio cache (non-blocking, graceful on error)
    _syncStudioCacheQuietly();

    // Load active session from local storage
    await loadActiveSession();

    // Listen for connectivity changes to trigger pending session sync
    _listenToConnectivity();

    state = state.copyWith(isInitialized: true);
  }

  /// Sync studio cache in background (non-blocking).
  Future<void> _syncStudioCacheQuietly() async {
    try {
      await _studioCache.syncStudios();
    } catch (_) {
      // Offline or error: use cached data — no action needed
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

  /// Sync pending cleaning sessions in background (non-blocking).
  Future<void> _syncPendingQuietly() async {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    try {
      await _service.syncPendingSessions(employeeId);
    } catch (_) {
      // Will retry on next connectivity change
    }
  }

  /// Trigger pending sync (callable from app resume or pull-to-refresh).
  Future<void> syncPending() async {
    await _syncPendingQuietly();
  }

  /// Load active cleaning session from local storage.
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

  /// Scan a QR code to start a new cleaning session.
  /// [shiftId] is the local shift ID (for local storage queries).
  /// [serverShiftId] is the Supabase shift ID (for RPC calls).
  Future<ScanResult> scanIn(String qrCode, String shiftId,
      {String? serverShiftId}) async {
    final employeeId = _employeeId;
    if (employeeId == null) {
      return ScanResult.error(ScanErrorType.noActiveShift);
    }

    state = state.copyWith(isScanning: true, clearError: true);

    try {
      // Capture GPS position at scan-in
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.scanIn(
        employeeId: employeeId,
        qrCode: qrCode,
        shiftId: shiftId,
        serverShiftId: serverShiftId,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
      );

      if (result.success && result.session != null) {
        state = state.copyWith(
          activeSession: result.session,
          isScanning: false,
        );
        // Update Live Activity with session info
        ShiftActivityService.instance.updateSessionInfo(
          sessionType: 'cleaning',
          sessionLocation: result.session!.studioLabel,
          sessionStartedAt: result.session!.startedAt,
        );
      } else {
        state = state.copyWith(
          isScanning: false,
          error: result.errorMessage,
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: 'Erreur lors du scan: $e',
      );
      return ScanResult.error(ScanErrorType.invalidQr,
          message: 'Erreur inattendue');
    }
  }

  /// Scan a QR code to complete an existing cleaning session.
  Future<ScanResult> scanOut(String qrCode) async {
    final employeeId = _employeeId;
    if (employeeId == null) {
      return ScanResult.error(ScanErrorType.noActiveSession);
    }

    state = state.copyWith(isScanning: true, clearError: true);

    try {
      // Capture GPS position at scan-out
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.scanOut(
        employeeId: employeeId,
        qrCode: qrCode,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
      );

      if (result.success) {
        state = state.copyWith(
          isScanning: false,
          clearActiveSession: true,
        );
        // Clear session info from Live Activity
        ShiftActivityService.instance.updateSessionInfo();
      } else {
        state = state.copyWith(
          isScanning: false,
          error: result.errorMessage,
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: 'Erreur lors du scan: $e',
      );
      return ScanResult.error(ScanErrorType.noActiveSession,
          message: 'Erreur inattendue');
    }
  }

  /// Manually close the active cleaning session (without scanning).
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

/// Provider for cleaning session state management.
final cleaningSessionProvider =
    StateNotifierProvider<CleaningSessionNotifier, CleaningSessionState>((ref) {
  final service = ref.watch(cleaningSessionServiceProvider);
  final studioCache = ref.watch(studioCacheServiceProvider);
  final user = ref.watch(currentUserProvider);
  return CleaningSessionNotifier(service, studioCache, user?.id, ref);
});

/// Provider for checking if employee has an active cleaning session.
final hasActiveCleaningSessionProvider = Provider<bool>((ref) {
  return ref.watch(cleaningSessionProvider).activeSession != null;
});

/// Provider for the active cleaning session.
final activeCleaningSessionProvider = Provider<CleaningSession?>((ref) {
  return ref.watch(cleaningSessionProvider).activeSession;
});

/// Provider for cleaning sessions in the current shift.
final shiftCleaningSessionsProvider =
    FutureProvider.family<List<CleaningSession>, String>(
        (ref, shiftId) async {
  final service = ref.watch(cleaningSessionServiceProvider);
  // Invalidate when active session changes (new scan-in/scan-out)
  ref.watch(cleaningSessionProvider);
  return service.getShiftSessions(shiftId);
});
