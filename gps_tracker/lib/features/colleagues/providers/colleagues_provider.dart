import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../models/colleague_status.dart';

class ColleaguesState {
  final List<ColleagueStatus> colleagues;
  final bool isLoading;
  final String? error;

  const ColleaguesState({
    this.colleagues = const [],
    this.isLoading = false,
    this.error,
  });

  ColleaguesState copyWith({
    List<ColleagueStatus>? colleagues,
    bool? isLoading,
    String? error,
  }) {
    return ColleaguesState(
      colleagues: colleagues ?? this.colleagues,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  int get onShiftCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.onShift).length;
  int get onLunchCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.onLunch).length;
  int get offShiftCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.offShift).length;
}

class ColleaguesNotifier extends StateNotifier<ColleaguesState> {
  final SupabaseClient _supabase;

  ColleaguesNotifier(this._supabase) : super(const ColleaguesState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response =
          await _supabase.schema('workforce').rpc<List<dynamic>>('get_colleagues_status');
      final colleagues = response
          .map(
            (json) => ColleagueStatus.fromJson(json as Map<String, dynamic>),
          )
          .toList();
      state = state.copyWith(colleagues: colleagues, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de charger la liste des collègues.',
      );
    }
  }

  Future<void> refresh() => load();
}

final colleaguesProvider =
    StateNotifierProvider.autoDispose<ColleaguesNotifier, ColleaguesState>(
  (ref) => ColleaguesNotifier(ref.watch(supabaseClientProvider)),
);
