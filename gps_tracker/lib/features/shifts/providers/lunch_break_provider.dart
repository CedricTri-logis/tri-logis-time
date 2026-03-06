import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/shift_activity_service.dart';
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

      // Stop GPS tracking
      await _ref.read(trackingProvider.notifier).stopTracking(reason: 'lunch_break');

      // Update iOS Live Activity
      ShiftActivityService.instance.updateStatus('lunch');
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
