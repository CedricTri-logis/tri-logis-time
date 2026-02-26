import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../models/shift_enums.dart';
import '../models/sync_metadata.dart';
import '../models/sync_progress.dart';
import '../services/backoff_strategy.dart';
import '../services/diagnostic_sync_service.dart';
import '../services/sync_logger.dart';
import '../services/sync_service.dart';
import 'connectivity_provider.dart';
import 'quarantine_provider.dart';
import 'shift_provider.dart';

/// Provider for DiagnosticSyncService.
final diagnosticSyncServiceProvider = Provider<DiagnosticSyncService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final localDb = ref.watch(localDatabaseProvider);
  return DiagnosticSyncService(supabase, localDb);
});

/// Provider for SyncService.
final syncServiceProvider = Provider<SyncService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final localDb = ref.watch(localDatabaseProvider);
  final shiftService = ref.watch(shiftServiceProvider);
  final syncService = SyncService(supabase, localDb, shiftService);
  // Inject quarantine service for orphaned GPS point handling
  syncService.setQuarantineService(ref.watch(quarantineServiceProvider));
  // Inject diagnostic sync service for log upload
  syncService.setDiagnosticSyncService(ref.watch(diagnosticSyncServiceProvider));
  return syncService;
});

/// Provider for SyncLogger.
final syncLoggerProvider = Provider<SyncLogger>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return SyncLogger(localDb);
});

/// Enhanced state for sync status with persistence support.
class SyncState {
  final SyncStatus status;
  final int pendingShifts;
  final int pendingGpsPoints;
  final int pendingDiagnostics;
  final String? lastError;
  final DateTime? lastSyncTime;

  /// NEW: Active sync progress (for UI updates)
  final SyncProgress? progress;

  /// NEW: Number of consecutive failures (for backoff calculation)
  final int consecutiveFailures;

  /// NEW: Time until next retry
  final Duration? nextRetryIn;

  /// NEW: Whether sync is connected
  final bool isConnected;

  const SyncState({
    this.status = SyncStatus.synced,
    this.pendingShifts = 0,
    this.pendingGpsPoints = 0,
    this.pendingDiagnostics = 0,
    this.lastError,
    this.lastSyncTime,
    this.progress,
    this.consecutiveFailures = 0,
    this.nextRetryIn,
    this.isConnected = true,
  });

  bool get hasPendingData =>
      pendingShifts > 0 || pendingGpsPoints > 0 || pendingDiagnostics > 0;

  /// Total pending items count.
  int get totalPending => pendingShifts + pendingGpsPoints + pendingDiagnostics;

  /// Whether we're in a retry state.
  bool get isRetrying => consecutiveFailures > 0;

  /// Whether sync can be triggered (not syncing and has pending data).
  bool get canSync =>
      status != SyncStatus.syncing && hasPendingData && isConnected;

  SyncState copyWith({
    SyncStatus? status,
    int? pendingShifts,
    int? pendingGpsPoints,
    int? pendingDiagnostics,
    String? lastError,
    DateTime? lastSyncTime,
    SyncProgress? progress,
    int? consecutiveFailures,
    Duration? nextRetryIn,
    bool? isConnected,
    bool clearError = false,
    bool clearProgress = false,
    bool clearNextRetry = false,
  }) {
    return SyncState(
      status: status ?? this.status,
      pendingShifts: pendingShifts ?? this.pendingShifts,
      pendingGpsPoints: pendingGpsPoints ?? this.pendingGpsPoints,
      pendingDiagnostics: pendingDiagnostics ?? this.pendingDiagnostics,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      progress: clearProgress ? null : (progress ?? this.progress),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      nextRetryIn: clearNextRetry ? null : (nextRetryIn ?? this.nextRetryIn),
      isConnected: isConnected ?? this.isConnected,
    );
  }

  /// Create from persisted SyncMetadata.
  factory SyncState.fromMetadata(SyncMetadata metadata) {
    // Determine status from metadata
    SyncStatus status;
    if (metadata.syncInProgress) {
      status = SyncStatus.syncing;
    } else if (metadata.hasError) {
      status = SyncStatus.error;
    } else if (metadata.hasPendingData) {
      status = SyncStatus.pending;
    } else {
      status = SyncStatus.synced;
    }

    // Calculate next retry time if there are failures
    Duration? nextRetryIn;
    if (metadata.consecutiveFailures > 0 && metadata.currentBackoffSeconds > 0) {
      nextRetryIn = Duration(seconds: metadata.currentBackoffSeconds);
    }

    return SyncState(
      status: status,
      pendingShifts: metadata.pendingShiftsCount,
      pendingGpsPoints: metadata.pendingGpsPointsCount,
      pendingDiagnostics: 0,
      lastError: metadata.lastError,
      lastSyncTime: metadata.lastSuccessfulSync,
      consecutiveFailures: metadata.consecutiveFailures,
      nextRetryIn: nextRetryIn,
    );
  }

  /// Convert to SyncMetadata for persistence.
  SyncMetadata toMetadata() {
    final now = DateTime.now().toUtc();
    return SyncMetadata(
      lastSyncAttempt: status == SyncStatus.syncing ? now : null,
      lastSuccessfulSync: lastSyncTime,
      consecutiveFailures: consecutiveFailures,
      currentBackoffSeconds: nextRetryIn?.inSeconds ?? 0,
      syncInProgress: status == SyncStatus.syncing,
      lastError: lastError,
      pendingShiftsCount: pendingShifts,
      pendingGpsPointsCount: pendingGpsPoints,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// Notifier for managing sync state with persistence.
class SyncNotifier extends StateNotifier<SyncState> {
  final Ref _ref;
  StreamSubscription<bool>? _connectivitySub;
  Timer? _syncRetryTimer;
  Timer? _countdownTimer;
  StreamSubscription<SyncProgress>? _progressSub;

  /// Guarded access to the diagnostic logger singleton.
  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Delay before auto-sync on connectivity restore (cautious for flaky networks).
  static const Duration _connectivityRestoreDelay = Duration(seconds: 30);

  /// Delay before auto-sync when new data arrives (fast response).
  static const Duration _newDataDelay = Duration(seconds: 5);

  /// Backoff strategy instance.
  late ExponentialBackoff _backoff;

  SyncNotifier(this._ref) : super(const SyncState()) {
    _backoff = ExponentialBackoff();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load persisted state first
    await _loadPersistedState();

    // Listen to connectivity changes
    _listenToConnectivity();

    // Refresh pending counts
    await refreshPendingCounts();

    // Subscribe to sync progress from service
    _subscribeToProgress();

    // Auto-sync on startup if there's pending data (e.g. clock-out that
    // failed to reach the server before the app was killed/updated).
    // _scheduleSyncWithDelay checks hasPendingData && isConnected before firing.
    if (state.hasPendingData) {
      _scheduleSyncWithDelay(delay: const Duration(seconds: 5));
    }
  }

  /// Load sync state from persistence.
  Future<void> _loadPersistedState() async {
    try {
      final localDb = _ref.read(localDatabaseProvider);
      final metadata = await localDb.getSyncMetadata();
      final persistedState = SyncState.fromMetadata(metadata);

      // Restore backoff state
      _backoff = ExponentialBackoff.fromState(
        consecutiveFailures: metadata.consecutiveFailures,
      );

      state = persistedState.copyWith(isConnected: state.isConnected);

      _ref.read(syncLoggerProvider).debug(
        'Loaded persisted sync state',
        metadata: {
          'pending_shifts': persistedState.pendingShifts,
          'pending_gps_points': persistedState.pendingGpsPoints,
          'consecutive_failures': persistedState.consecutiveFailures,
        },
      );
    } catch (e) {
      // Continue with default state on error
      _ref.read(syncLoggerProvider).warn(
        'Failed to load persisted state',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Persist current state to database.
  Future<void> _persistState() async {
    try {
      final localDb = _ref.read(localDatabaseProvider);
      await localDb.updateSyncMetadata(state.toMetadata());
    } catch (e) {
      // Log but don't fail
      _ref.read(syncLoggerProvider).warn(
        'Failed to persist sync state',
        metadata: {'error': e.toString()},
      );
    }
  }

  void _listenToConnectivity() {
    _connectivitySub = _ref
        .read(connectivityServiceProvider)
        .onConnectivityChanged
        .listen((isConnected) {
      state = state.copyWith(isConnected: isConnected);

      _ref.read(syncLoggerProvider).connectivityChanged(
            isConnected: isConnected,
          );

      _logger?.network(
        isConnected ? Severity.info : Severity.warn,
        'Connectivity changed',
        metadata: {'connected': isConnected},
      );

      if (isConnected && state.hasPendingData) {
        _scheduleSyncWithDelay(delay: _connectivityRestoreDelay);
      } else if (!isConnected) {
        // Cancel any pending retries when disconnected
        _cancelRetryTimer();
      }
    });
  }

  void _subscribeToProgress() {
    final syncService = _ref.read(syncServiceProvider);
    _progressSub = syncService.progressStream.listen((progress) {
      state = state.copyWith(progress: progress);
    });
  }

  /// Schedule sync after a delay. Uses [_newDataDelay] by default.
  void _scheduleSyncWithDelay({Duration? delay}) {
    _cancelRetryTimer();

    final effectiveDelay = delay ?? _newDataDelay;

    _syncRetryTimer = Timer(effectiveDelay, () {
      if (state.hasPendingData && state.isConnected) {
        syncPendingData();
      }
    });

    _ref.read(syncLoggerProvider).debug(
      'Sync scheduled',
      metadata: {'delay_seconds': effectiveDelay.inSeconds},
    );
  }

  /// Schedule retry with exponential backoff.
  void _scheduleRetryWithBackoff() {
    _cancelRetryTimer();

    final delay = _backoff.getDelay();
    state = state.copyWith(nextRetryIn: delay);

    _ref.read(syncLoggerProvider).backoffScheduled(
          attempt: _backoff.attempt,
          delay: delay,
        );

    // Start countdown timer for UI updates
    _startCountdownTimer(delay);

    _syncRetryTimer = Timer(delay, () {
      if (state.hasPendingData && state.isConnected) {
        syncPendingData();
      }
    });
  }

  void _startCountdownTimer(Duration initialDelay) {
    _countdownTimer?.cancel();

    var remaining = initialDelay;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remaining = Duration(seconds: remaining.inSeconds - 1);

      if (remaining.inSeconds <= 0) {
        timer.cancel();
        state = state.copyWith(clearNextRetry: true);
      } else {
        state = state.copyWith(nextRetryIn: remaining);
      }
    });
  }

  void _cancelRetryTimer() {
    _syncRetryTimer?.cancel();
    _countdownTimer?.cancel();
    state = state.copyWith(clearNextRetry: true);
  }

  /// Refresh pending data counts from database.
  Future<void> refreshPendingCounts() async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      final counts = await syncService.getPendingCounts();

      final newStatus = counts.shifts > 0 ||
              counts.gpsPoints > 0 ||
              counts.diagnostics > 0
          ? (state.status == SyncStatus.syncing
              ? SyncStatus.syncing
              : SyncStatus.pending)
          : SyncStatus.synced;

      state = state.copyWith(
        pendingShifts: counts.shifts,
        pendingGpsPoints: counts.gpsPoints,
        pendingDiagnostics: counts.diagnostics,
        status: newStatus,
      );

      // Update persisted counts
      final localDb = _ref.read(localDatabaseProvider);
      await localDb.updatePendingCounts(counts.shifts, counts.gpsPoints);
    } catch (e) {
      // Ignore errors during count check
    }
  }

  /// Manually trigger sync of pending data.
  Future<void> syncPendingData() async {
    if (state.status == SyncStatus.syncing) return;

    // Check connectivity first
    final isConnected =
        await _ref.read(connectivityServiceProvider).isConnected();
    if (!isConnected) {
      state = state.copyWith(status: SyncStatus.pending, isConnected: false);
      return;
    }

    // Check if there's pending data
    await refreshPendingCounts();
    if (!state.hasPendingData) {
      state = state.copyWith(
        status: SyncStatus.synced,
        clearError: true,
        clearProgress: true,
      );
      await _persistState();
      return;
    }

    // Start sync
    state = state.copyWith(
      status: SyncStatus.syncing,
      clearError: true,
      progress: SyncProgress.initial(
        totalShifts: state.pendingShifts,
        totalGpsPoints: state.pendingGpsPoints,
      ),
    );

    final logger = _ref.read(syncLoggerProvider);
    await logger.syncStarted(
      pendingShifts: state.pendingShifts,
      pendingGpsPoints: state.pendingGpsPoints,
    );

    final localDb = _ref.read(localDatabaseProvider);
    await localDb.markSyncStarted();

    final startTime = DateTime.now();

    try {
      final syncService = _ref.read(syncServiceProvider);
      final result = await syncService.syncAll();

      final duration = DateTime.now().difference(startTime);

      if (result.hasErrors) {
        // Sync had errors - schedule retry
        _backoff = ExponentialBackoff.fromState(
          consecutiveFailures: state.consecutiveFailures + 1,
        );

        final backoffDelay = _backoff.getDelay();

        state = state.copyWith(
          status: SyncStatus.error,
          pendingShifts: result.failedShifts,
          pendingGpsPoints: result.failedGpsPoints,
          pendingDiagnostics: state.pendingDiagnostics,
          lastError: result.lastError,
          consecutiveFailures: state.consecutiveFailures + 1,
          clearProgress: true,
        );

        await localDb.markSyncFailed(
          result.lastError ?? 'Unknown error',
          backoffDelay.inSeconds,
        );

        await logger.syncFailed(
          error: result.lastError ?? 'Unknown error',
          attemptNumber: state.consecutiveFailures,
          nextRetryIn: backoffDelay,
        );

        // Schedule retry if we're still connected
        if (state.isConnected) {
          _scheduleRetryWithBackoff();
        }
      } else {
        // Sync successful - reset backoff
        _backoff.reset();

        state = state.copyWith(
          status: SyncStatus.synced,
          pendingShifts: 0,
          pendingGpsPoints: 0,
          pendingDiagnostics: 0,
          lastSyncTime: DateTime.now(),
          consecutiveFailures: 0,
          clearError: true,
          clearProgress: true,
          clearNextRetry: true,
        );

        await localDb.markSyncSuccess();

        await logger.syncCompleted(
          syncedShifts: result.syncedShifts,
          syncedGpsPoints: result.syncedGpsPoints,
          failedShifts: 0,
          failedGpsPoints: 0,
          duration: duration,
        );
      }

      await _persistState();
    } catch (e) {
      // Unexpected error - schedule retry
      _backoff = ExponentialBackoff.fromState(
        consecutiveFailures: state.consecutiveFailures + 1,
      );

      final backoffDelay = _backoff.getDelay();

      state = state.copyWith(
        status: SyncStatus.error,
        lastError: e.toString(),
        consecutiveFailures: state.consecutiveFailures + 1,
        clearProgress: true,
      );

      await localDb.markSyncFailed(e.toString(), backoffDelay.inSeconds);

      await logger.syncFailed(
        error: e.toString(),
        attemptNumber: state.consecutiveFailures,
        nextRetryIn: backoffDelay,
      );

      await _persistState();

      // Schedule retry if we're still connected
      if (state.isConnected) {
        _scheduleRetryWithBackoff();
      }
    }
  }

  /// Notify that new data needs sync.
  void notifyPendingData() {
    refreshPendingCounts();

    // Only schedule sync if not already syncing and we have a connection
    if (state.status != SyncStatus.syncing && state.isConnected) {
      // Don't override active backoff timer — let the retry schedule run
      if (state.consecutiveFailures > 0 && _syncRetryTimer?.isActive == true) {
        return;
      }
      _scheduleSyncWithDelay();
    }
  }

  /// Clear error and retry sync immediately.
  void retrySync() {
    _backoff.reset();
    _cancelRetryTimer();
    state = state.copyWith(
      consecutiveFailures: 0,
      clearError: true,
      clearNextRetry: true,
    );
    syncPendingData();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _syncRetryTimer?.cancel();
    _countdownTimer?.cancel();
    _progressSub?.cancel();
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

/// Provider for pending data count.
final pendingDataCountProvider = Provider<int>((ref) {
  return ref.watch(syncProvider).totalPending;
});

/// Provider for whether there is pending data.
final hasPendingDataProvider = Provider<bool>((ref) {
  return ref.watch(syncProvider).hasPendingData;
});
