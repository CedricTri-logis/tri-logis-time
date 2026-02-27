import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../shifts/providers/connectivity_provider.dart';
import '../../shifts/providers/location_provider.dart';
import '../../shifts/providers/shift_provider.dart';
import '../models/maintenance_session.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../services/maintenance_local_db.dart';
import '../services/maintenance_session_service.dart';
import '../services/property_cache_service.dart';

/// Provider for MaintenanceLocalDb instance.
final maintenanceLocalDbProvider = Provider<MaintenanceLocalDb>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return MaintenanceLocalDb(localDb);
});

/// Provider for PropertyCacheService.
final propertyCacheServiceProvider = Provider<PropertyCacheService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final maintenanceDb = ref.watch(maintenanceLocalDbProvider);
  return PropertyCacheService(supabase, maintenanceDb);
});

/// Provider for MaintenanceSessionService.
final maintenanceSessionServiceProvider =
    Provider<MaintenanceSessionService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final maintenanceDb = ref.watch(maintenanceLocalDbProvider);
  final cleaningDb = ref.watch(cleaningLocalDbProvider);
  return MaintenanceSessionService(supabase, maintenanceDb, cleaningDb);
});

/// State for maintenance session operations.
class MaintenanceSessionState {
  final MaintenanceSession? activeSession;
  final bool isLoading;
  final String? error;
  final bool isInitialized;

  const MaintenanceSessionState({
    this.activeSession,
    this.isLoading = false,
    this.error,
    this.isInitialized = false,
  });

  MaintenanceSessionState copyWith({
    MaintenanceSession? activeSession,
    bool? isLoading,
    String? error,
    bool? isInitialized,
    bool clearActiveSession = false,
    bool clearError = false,
  }) {
    return MaintenanceSessionState(
      activeSession:
          clearActiveSession ? null : (activeSession ?? this.activeSession),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

/// Notifier for managing maintenance session state.
class MaintenanceSessionNotifier
    extends StateNotifier<MaintenanceSessionState> {
  final MaintenanceSessionService _service;
  final String? _employeeId;
  final Ref _ref;
  StreamSubscription<bool>? _connectivitySub;

  MaintenanceSessionNotifier(
    this._service,
    this._employeeId,
    this._ref,
  ) : super(const MaintenanceSessionState()) {
    if (_employeeId != null) {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    await loadActiveSession();
    _listenToConnectivity();
    _syncPropertyCacheQuietly();
    state = state.copyWith(isInitialized: true);
  }

  /// Sync property buildings + apartments cache from Supabase (fire-and-forget).
  Future<void> _syncPropertyCacheQuietly() async {
    try {
      final propertyCache = _ref.read(propertyCacheServiceProvider);
      await propertyCache.syncProperties();
    } catch (_) {
      // Will use existing local cache
    }
  }

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

  Future<void> _syncPendingQuietly() async {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    try {
      await _service.syncPendingSessions(employeeId);
    } catch (_) {
      // Will retry on next connectivity change
    }
  }

  Future<void> syncPending() async {
    await _syncPendingQuietly();
  }

  /// Load active maintenance session from local storage.
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

  /// Start a new maintenance session.
  Future<MaintenanceSessionResult> startSession({
    required String shiftId,
    required String buildingId,
    required String buildingName,
    String? apartmentId,
    String? unitNumber,
    String? serverShiftId,
  }) async {
    final employeeId = _employeeId;
    if (employeeId == null) {
      return MaintenanceSessionResult.error('Non authentifié');
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      // Capture GPS position at session start
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.startSession(
        employeeId: employeeId,
        shiftId: shiftId,
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
          isLoading: false,
        );
        // Update Live Activity with session info
        ShiftActivityService.instance.updateSessionInfo(
          sessionType: 'maintenance',
          sessionLocation: result.session!.locationLabel,
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: result.errorMessage,
        );
      }

      return result;
    } catch (e, st) {
      // ignore: avoid_print
      print('MaintenanceSessionNotifier.startSession ERROR: $e');
      // ignore: avoid_print
      print('Stack trace: $st');
      state = state.copyWith(
        isLoading: false,
        error: 'Erreur: $e',
      );
      return MaintenanceSessionResult.error('Erreur inattendue: $e');
    }
  }

  /// Complete the active maintenance session.
  Future<bool> completeSession() async {
    final employeeId = _employeeId;
    if (employeeId == null) return false;

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      // Capture GPS position at session end
      final locationService = _ref.read(locationServiceProvider);
      final position = await locationService.getCurrentPosition();

      final result = await _service.completeSession(
        employeeId: employeeId,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracy: position?.accuracy,
      );
      if (result.success) {
        state = state.copyWith(
          isLoading: false,
          clearActiveSession: true,
        );
        // Clear session info from Live Activity
        ShiftActivityService.instance.updateSessionInfo();
        return true;
      } else {
        state = state.copyWith(
          isLoading: false,
          error: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Erreur lors de la complétion: $e',
      );
      return false;
    }
  }

  /// Manually close the active maintenance session.
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

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}

/// Provider for maintenance session state management.
final maintenanceSessionProvider = StateNotifierProvider<
    MaintenanceSessionNotifier, MaintenanceSessionState>((ref) {
  final service = ref.watch(maintenanceSessionServiceProvider);
  final user = ref.watch(currentUserProvider);
  return MaintenanceSessionNotifier(service, user?.id, ref);
});

/// Provider for checking if employee has an active maintenance session.
final hasActiveMaintenanceSessionProvider = Provider<bool>((ref) {
  return ref.watch(maintenanceSessionProvider).activeSession != null;
});

/// Provider for the active maintenance session.
final activeMaintenanceSessionProvider =
    Provider<MaintenanceSession?>((ref) {
  return ref.watch(maintenanceSessionProvider).activeSession;
});

/// Provider for maintenance sessions in the current shift.
final shiftMaintenanceSessionsProvider =
    FutureProvider.family<List<MaintenanceSession>, String>(
        (ref, shiftId) async {
  final service = ref.watch(maintenanceSessionServiceProvider);
  // Invalidate when active session changes
  ref.watch(maintenanceSessionProvider);
  return service.getShiftSessions(shiftId);
});
