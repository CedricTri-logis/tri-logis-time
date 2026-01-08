import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../models/shift_enums.dart';
import '../services/sync_service.dart';
import 'connectivity_provider.dart';
import 'shift_provider.dart';

/// Provider for SyncService.
final syncServiceProvider = Provider<SyncService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final localDb = ref.watch(localDatabaseProvider);
  final shiftService = ref.watch(shiftServiceProvider);
  return SyncService(supabase, localDb, shiftService);
});

/// State for sync status.
class SyncState {
  final SyncStatus status;
  final int pendingShifts;
  final int pendingGpsPoints;
  final String? lastError;
  final DateTime? lastSyncTime;

  const SyncState({
    this.status = SyncStatus.synced,
    this.pendingShifts = 0,
    this.pendingGpsPoints = 0,
    this.lastError,
    this.lastSyncTime,
  });

  bool get hasPendingData => pendingShifts > 0 || pendingGpsPoints > 0;

  SyncState copyWith({
    SyncStatus? status,
    int? pendingShifts,
    int? pendingGpsPoints,
    String? lastError,
    DateTime? lastSyncTime,
    bool clearError = false,
  }) {
    return SyncState(
      status: status ?? this.status,
      pendingShifts: pendingShifts ?? this.pendingShifts,
      pendingGpsPoints: pendingGpsPoints ?? this.pendingGpsPoints,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    );
  }
}

/// Notifier for managing sync state.
class SyncNotifier extends StateNotifier<SyncState> {
  final Ref _ref;
  StreamSubscription<bool>? _connectivitySub;
  Timer? _syncDebounceTimer;

  static const Duration _syncDebounce = Duration(seconds: 5);

  SyncNotifier(this._ref) : super(const SyncState()) {
    _initialize();
  }

  void _initialize() {
    _listenToConnectivity();
    _checkPendingData();
  }

  void _listenToConnectivity() {
    _connectivitySub = _ref
        .read(connectivityServiceProvider)
        .onConnectivityChanged
        .listen((isConnected) {
      if (isConnected) {
        _scheduleSyncIfNeeded();
      }
    });
  }

  void _scheduleSyncIfNeeded() {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(_syncDebounce, () {
      syncPendingData();
    });
  }

  Future<void> _checkPendingData() async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      final counts = await syncService.getPendingCounts();

      state = state.copyWith(
        pendingShifts: counts.shifts,
        pendingGpsPoints: counts.gpsPoints,
        status: counts.shifts > 0 || counts.gpsPoints > 0
            ? SyncStatus.pending
            : SyncStatus.synced,
      );
    } catch (e) {
      // Ignore errors during initial check
    }
  }

  /// Manually trigger sync of pending data.
  Future<void> syncPendingData() async {
    if (state.status == SyncStatus.syncing) return;

    final hasPending = await _ref.read(syncServiceProvider).hasPendingData();
    if (!hasPending) {
      state = state.copyWith(
        status: SyncStatus.synced,
        pendingShifts: 0,
        pendingGpsPoints: 0,
        clearError: true,
      );
      return;
    }

    state = state.copyWith(status: SyncStatus.syncing, clearError: true);

    try {
      final isConnected =
          await _ref.read(connectivityServiceProvider).isConnected();
      if (!isConnected) {
        state = state.copyWith(status: SyncStatus.pending);
        return;
      }

      final syncService = _ref.read(syncServiceProvider);
      final result = await syncService.syncAll();

      if (result.hasErrors) {
        state = state.copyWith(
          status: SyncStatus.error,
          pendingShifts: result.failedShifts,
          pendingGpsPoints: result.failedGpsPoints,
          lastError: result.lastError,
          lastSyncTime: DateTime.now(),
        );
      } else {
        state = state.copyWith(
          status: SyncStatus.synced,
          pendingShifts: 0,
          pendingGpsPoints: 0,
          lastSyncTime: DateTime.now(),
          clearError: true,
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: SyncStatus.error,
        lastError: e.toString(),
      );
    }
  }

  /// Notify that new data needs sync.
  void notifyPendingData() {
    _checkPendingData();
    _scheduleSyncIfNeeded();
  }

  /// Clear error and retry sync.
  void retrySync() {
    state = state.copyWith(clearError: true);
    syncPendingData();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _syncDebounceTimer?.cancel();
    super.dispose();
  }
}

/// Provider for sync state management.
final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  return SyncNotifier(ref);
});

/// Provider for overall sync status.
final syncStatusProvider = Provider<SyncStatus>((ref) {
  return ref.watch(syncProvider).status;
});

/// Provider for checking if sync is in progress.
final isSyncingProvider = Provider<bool>((ref) {
  return ref.watch(syncProvider).status == SyncStatus.syncing;
});
