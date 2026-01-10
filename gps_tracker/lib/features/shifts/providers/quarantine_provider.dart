import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/quarantined_record.dart';
import '../services/quarantine_service.dart';
import 'shift_provider.dart';
import 'sync_provider.dart';

/// Provider for QuarantineService.
final quarantineServiceProvider = Provider<QuarantineService>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  final logger = ref.watch(syncLoggerProvider);
  return QuarantineService(localDb, logger);
});

/// State for quarantine management.
class QuarantineState {
  final List<QuarantinedRecord> records;
  final QuarantineStats stats;
  final bool isLoading;
  final String? error;

  const QuarantineState({
    this.records = const [],
    this.stats = const QuarantineStats(pendingShifts: 0, pendingGpsPoints: 0),
    this.isLoading = false,
    this.error,
  });

  bool get hasRecords => records.isNotEmpty;
  int get totalRecords => stats.total;

  QuarantineState copyWith({
    List<QuarantinedRecord>? records,
    QuarantineStats? stats,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return QuarantineState(
      records: records ?? this.records,
      stats: stats ?? this.stats,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Default stats constant.
class QuarantineStats {
  final int pendingShifts;
  final int pendingGpsPoints;

  const QuarantineStats({
    required this.pendingShifts,
    required this.pendingGpsPoints,
  });

  int get total => pendingShifts + pendingGpsPoints;
}

/// Notifier for quarantine state management.
class QuarantineNotifier extends StateNotifier<QuarantineState> {
  final Ref _ref;

  QuarantineNotifier(this._ref) : super(const QuarantineState()) {
    refresh();
  }

  /// Refresh quarantine state.
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(quarantineServiceProvider);
      final records = await service.getPendingRecords();
      final serviceStats = await service.getStats();

      state = state.copyWith(
        records: records,
        stats: QuarantineStats(
          pendingShifts: serviceStats.pendingShifts,
          pendingGpsPoints: serviceStats.pendingGpsPoints,
        ),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load quarantine: $e',
      );
    }
  }

  /// Retry a specific record.
  Future<bool> retryRecord(QuarantinedRecord record) async {
    try {
      final service = _ref.read(quarantineServiceProvider);

      bool success;
      if (record.recordType == RecordType.shift) {
        success = await service.retryShift(record);
      } else {
        success = await service.retryGpsPoint(record);
      }

      if (success) {
        // Refresh list and trigger sync
        await refresh();
        _ref.read(syncProvider.notifier).notifyPendingData();
      }

      return success;
    } catch (e) {
      state = state.copyWith(error: 'Failed to retry: $e');
      return false;
    }
  }

  /// Discard a specific record.
  Future<void> discardRecord(QuarantinedRecord record, String reason) async {
    try {
      final service = _ref.read(quarantineServiceProvider);
      await service.discardRecord(record.id, reason: reason);
      await refresh();
    } catch (e) {
      state = state.copyWith(error: 'Failed to discard: $e');
    }
  }

  /// Retry all pending records.
  Future<RetryResult> retryAll() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(quarantineServiceProvider);
      final result = await service.retryAll();

      await refresh();
      _ref.read(syncProvider.notifier).notifyPendingData();

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to retry all: $e',
      );
      return RetryResult(retried: 0, failed: 0);
    }
  }

  /// Discard all records of a type.
  Future<int> discardAllOfType(RecordType type, String reason) async {
    try {
      final service = _ref.read(quarantineServiceProvider);
      final count = await service.discardAllOfType(type, reason: reason);
      await refresh();
      return count;
    } catch (e) {
      state = state.copyWith(error: 'Failed to discard: $e');
      return 0;
    }
  }
}

/// Provider for quarantine state management.
final quarantineProvider =
    StateNotifierProvider<QuarantineNotifier, QuarantineState>((ref) {
  return QuarantineNotifier(ref);
});

/// Provider for whether there are quarantined records.
final hasQuarantinedRecordsProvider = Provider<bool>((ref) {
  return ref.watch(quarantineProvider).hasRecords;
});

/// Provider for quarantine record count.
final quarantineCountProvider = Provider<int>((ref) {
  return ref.watch(quarantineProvider).totalRecords;
});
