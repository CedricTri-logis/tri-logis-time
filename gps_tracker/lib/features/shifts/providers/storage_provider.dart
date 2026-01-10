import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/storage_metrics.dart';
import '../services/storage_monitor.dart';
import 'shift_provider.dart';
import 'sync_provider.dart';

/// Provider for StorageMonitor service.
final storageMonitorProvider = Provider<StorageMonitor>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return StorageMonitor(localDb);
});

/// State for storage monitoring.
class StorageState {
  final StorageMetrics metrics;
  final StorageBreakdown? breakdown;
  final bool isLoading;
  final bool showWarning;
  final DateTime? lastCleanup;
  final String? error;

  const StorageState({
    required this.metrics,
    this.breakdown,
    this.isLoading = false,
    this.showWarning = false,
    this.lastCleanup,
    this.error,
  });

  /// Check if storage is at warning level.
  bool get isWarning => metrics.isWarning;

  /// Check if storage is at critical level.
  bool get isCritical => metrics.isCritical;

  /// Get formatted usage string.
  String get usageString =>
      '${metrics.formattedUsed} / ${metrics.formattedTotal}';

  /// Get usage percentage.
  double get usagePercent => metrics.usagePercent;

  StorageState copyWith({
    StorageMetrics? metrics,
    StorageBreakdown? breakdown,
    bool? isLoading,
    bool? showWarning,
    DateTime? lastCleanup,
    String? error,
    bool clearError = false,
    bool clearBreakdown = false,
  }) {
    return StorageState(
      metrics: metrics ?? this.metrics,
      breakdown: clearBreakdown ? null : (breakdown ?? this.breakdown),
      isLoading: isLoading ?? this.isLoading,
      showWarning: showWarning ?? this.showWarning,
      lastCleanup: lastCleanup ?? this.lastCleanup,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier for storage state management.
class StorageNotifier extends StateNotifier<StorageState> {
  final Ref _ref;
  Timer? _periodicCheckTimer;

  static const Duration _checkInterval = Duration(minutes: 30);

  StorageNotifier(this._ref)
      : super(StorageState(metrics: StorageMetrics.defaults())) {
    _initialize();
  }

  Future<void> _initialize() async {
    await refresh();
    _startPeriodicCheck();
  }

  void _startPeriodicCheck() {
    _periodicCheckTimer?.cancel();
    _periodicCheckTimer = Timer.periodic(_checkInterval, (_) => refresh());
  }

  /// Refresh storage metrics.
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final monitor = _ref.read(storageMonitorProvider);
      final metrics = await monitor.checkStorage();
      final breakdown = await monitor.getBreakdown();

      state = state.copyWith(
        metrics: metrics,
        breakdown: breakdown,
        isLoading: false,
        showWarning: metrics.isWarning,
      );

      // Log if warning/critical
      if (metrics.isCritical) {
        _ref.read(syncLoggerProvider).warn(
          'Storage critical: ${metrics.usagePercent.toStringAsFixed(1)}%',
          metadata: {'used': metrics.usedBytes, 'total': metrics.totalCapacityBytes},
        );
      } else if (metrics.isWarning) {
        _ref.read(syncLoggerProvider).info(
          'Storage warning: ${metrics.usagePercent.toStringAsFixed(1)}%',
          metadata: {'used': metrics.usedBytes, 'total': metrics.totalCapacityBytes},
        );
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to check storage: $e',
      );
    }
  }

  /// Perform storage cleanup.
  Future<CleanupResult?> performCleanup() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final monitor = _ref.read(storageMonitorProvider);
      final result = await monitor.performCleanup();

      state = state.copyWith(
        metrics: result.newMetrics,
        isLoading: false,
        lastCleanup: DateTime.now(),
        showWarning: result.newMetrics.isWarning,
      );

      _ref.read(syncLoggerProvider).info(
        'Storage cleanup: deleted ${result.totalDeleted} records',
        metadata: {
          'gps_points': result.deletedGpsPoints,
          'logs': result.deletedLogs,
          'new_usage_percent': result.newMetrics.usagePercent,
        },
      );

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Cleanup failed: $e',
      );
      return null;
    }
  }

  /// Dismiss warning banner.
  void dismissWarning() {
    state = state.copyWith(showWarning: false);
  }

  @override
  void dispose() {
    _periodicCheckTimer?.cancel();
    super.dispose();
  }
}

/// Provider for storage state management.
final storageProvider =
    StateNotifierProvider<StorageNotifier, StorageState>((ref) {
  return StorageNotifier(ref);
});

/// Provider for storage usage percentage.
final storageUsagePercentProvider = Provider<double>((ref) {
  return ref.watch(storageProvider).usagePercent;
});

/// Provider for whether storage warning should be shown.
final showStorageWarningProvider = Provider<bool>((ref) {
  return ref.watch(storageProvider).showWarning;
});

/// Provider for whether storage is at critical level.
final isStorageCriticalProvider = Provider<bool>((ref) {
  return ref.watch(storageProvider).isCritical;
});
