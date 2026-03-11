import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../../tracking/providers/gps_health_guard_provider.dart';
import '../../tracking/providers/tracking_provider.dart';
import '../models/lunch_break.dart';
import 'shift_provider.dart';
import 'sync_provider.dart';

class LunchBreakState {
  final LunchBreak? activeLunchBreak;
  final bool isStarting;
  final bool isEnding;
  final String? error;

  const LunchBreakState({
    this.activeLunchBreak,
    this.isStarting = false,
    this.isEnding = false,
    this.error,
  });

  bool get isOnLunch => activeLunchBreak != null;

  LunchBreakState copyWith({
    LunchBreak? activeLunchBreak,
    bool? isStarting,
    bool? isEnding,
    String? error,
    bool clearActiveLunchBreak = false,
    bool clearError = false,
  }) {
    return LunchBreakState(
      activeLunchBreak: clearActiveLunchBreak
          ? null
          : (activeLunchBreak ?? this.activeLunchBreak),
      isStarting: isStarting ?? this.isStarting,
      isEnding: isEnding ?? this.isEnding,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LunchBreakNotifier extends StateNotifier<LunchBreakState> {
  final Ref _ref;
  final LocalDatabase _localDb;

  LunchBreakNotifier(this._ref, this._localDb)
      : super(const LunchBreakState()) {
    _init();
  }

  Future<void> _init() async {
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null) return;

    final openBreak = await _localDb.getActiveLunchBreak(shift.id);
    if (openBreak != null) {
      state = state.copyWith(activeLunchBreak: LunchBreak.fromMap(openBreak));
    }
  }

  Future<void> startLunchBreak() async {
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null || state.isOnLunch) return;

    state = state.copyWith(isStarting: true, clearError: true);

    try {
      // DB-level check: if _init() hasn't completed yet, there may be an
      // active lunch in the local DB that isn't reflected in memory state.
      final existingOpen = await _localDb.getActiveLunchBreak(shift.id);
      if (existingOpen != null) {
        // Restore the existing lunch break instead of creating a new one
        state = state.copyWith(
          activeLunchBreak: LunchBreak.fromMap(existingOpen),
          isStarting: false,
        );
        return;
      }

      final id = const Uuid().v4();
      final now = DateTime.now().toUtc();

      await _localDb.insertLunchBreak(
        id: id,
        shiftId: shift.id,
        employeeId: shift.employeeId,
        startedAt: now,
      );

      final lunchBreak = LunchBreak(
        id: id,
        shiftId: shift.id,
        employeeId: shift.employeeId,
        startedAt: now,
        createdAt: now,
      );

      state = state.copyWith(
        activeLunchBreak: lunchBreak,
        isStarting: false,
      );

      // Refresh lunch breaks list so timer picks it up
      _ref.invalidate(lunchBreaksForShiftProvider(shift.id));

      // Pause GPS tracking but keep resilience mechanisms (SLC, BAS, BGAppRefresh)
      // alive so iOS can relaunch the app if it gets killed during lunch
      await _ref.read(trackingProvider.notifier).pauseForLunch();

      // Update iOS Live Activity
      ShiftActivityService.instance.updateStatus('lunch');

      // Sync lunch break start to Supabase so dashboard shows it
      _ref.read(syncProvider.notifier).notifyPendingData();
    } catch (e) {
      state = state.copyWith(
        isStarting: false,
        error: 'Erreur: $e',
      );
    }
  }

  Future<void> endLunchBreak() async {
    final lunchBreak = state.activeLunchBreak;
    if (lunchBreak == null) return;

    state = state.copyWith(isEnding: true, clearError: true);

    try {
      final now = DateTime.now().toUtc();

      await _localDb.endLunchBreak(lunchBreak.id, now);

      state = state.copyWith(
        clearActiveLunchBreak: true,
        isEnding: false,
      );

      // Refresh lunch breaks list so timer shows accumulated time
      _ref.invalidate(lunchBreaksForShiftProvider(lunchBreak.shiftId));

      // Ensure GPS is alive before resuming tracking
      await ensureGpsAlive(_ref, source: 'lunch_end');

      // Resume GPS tracking
      await _ref.read(trackingProvider.notifier).startTracking();

      // Update iOS Live Activity back to active
      ShiftActivityService.instance.updateStatus('active');

      // Trigger sync of the completed lunch break
      _ref.read(syncProvider.notifier).notifyPendingData();
    } catch (e) {
      state = state.copyWith(
        isEnding: false,
        error: 'Erreur: $e',
      );
    }
  }

  void clearOnShiftEnd() {
    state = const LunchBreakState();
  }
}

final lunchBreakProvider =
    StateNotifierProvider<LunchBreakNotifier, LunchBreakState>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return LunchBreakNotifier(ref, localDb);
});

final isOnLunchProvider = Provider<bool>((ref) {
  return ref.watch(lunchBreakProvider).isOnLunch;
});

/// Provider that fetches all lunch breaks for a given shift from local DB.
final lunchBreaksForShiftProvider =
    FutureProvider.family<List<LunchBreak>, String>((ref, shiftId) async {
  final localDb = ref.watch(localDatabaseProvider);
  final rows = await localDb.getLunchBreaksForShift(shiftId);
  return rows.map((r) => LunchBreak.fromMap(r)).toList();
});

/// Total lunch duration for a shift (completed breaks only).
final totalLunchDurationProvider =
    FutureProvider.family<Duration, String>((ref, shiftId) async {
  final breaks = await ref.watch(lunchBreaksForShiftProvider(shiftId).future);
  var total = Duration.zero;
  for (final lb in breaks) {
    if (lb.endedAt != null) {
      total += lb.endedAt!.difference(lb.startedAt);
    }
  }
  return total;
});
