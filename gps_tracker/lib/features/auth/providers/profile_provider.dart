import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../models/employee_profile.dart';

/// Exception for profile operations
class ProfileException implements Exception {
  final String message;

  const ProfileException(this.message);

  @override
  String toString() => 'ProfileException: $message';
}

/// State for profile loading/updating
class ProfileState {
  final EmployeeProfile? profile;
  final bool isLoading;
  final String? error;

  const ProfileState({
    this.profile,
    this.isLoading = false,
    this.error,
  });

  ProfileState copyWith({
    EmployeeProfile? profile,
    bool? isLoading,
    String? error,
  }) {
    return ProfileState(
      profile: profile ?? this.profile,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier for managing profile state
class ProfileNotifier extends StateNotifier<ProfileState> {
  final SupabaseClient _client;

  ProfileNotifier(this._client) : super(const ProfileState());

  /// Fetch the current user's profile
  Future<void> fetchProfile() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      state = const ProfileState(error: 'Non authentifié');
      return;
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _client
          .from('employee_profiles')
          .select()
          .eq('id', userId)
          .single();

      final profile = EmployeeProfile.fromJson(response);
      state = ProfileState(profile: profile);
    } on PostgrestException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de charger le profil : ${e.message}',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de charger le profil. Veuillez réessayer.',
      );
    }
  }

  /// Update the current user's profile
  Future<void> updateProfile({
    String? fullName,
    String? employeeId,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const ProfileException('Non authentifié');
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      final updates = <String, dynamic>{
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (fullName != null) {
        updates['full_name'] = fullName.trim().isEmpty ? null : fullName.trim();
      }
      if (employeeId != null) {
        updates['employee_id'] =
            employeeId.trim().isEmpty ? null : employeeId.trim();
      }

      final response = await _client
          .from('employee_profiles')
          .update(updates)
          .eq('id', userId)
          .select()
          .single();

      final profile = EmployeeProfile.fromJson(response);
      state = ProfileState(profile: profile);
    } on PostgrestException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de mettre à jour le profil : ${e.message}',
      );
      rethrow;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de mettre à jour le profil. Veuillez réessayer.',
      );
      rethrow;
    }
  }

  /// Clear profile state (e.g., on sign out)
  void clear() {
    state = const ProfileState();
  }
}

/// Provider for profile state
final profileProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ProfileNotifier(client);
});

/// Provider that auto-fetches profile when accessed
final currentProfileProvider = FutureProvider<EmployeeProfile?>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final userId = client.auth.currentUser?.id;

  if (userId == null) return null;

  try {
    final response = await client
        .from('employee_profiles')
        .select()
        .eq('id', userId)
        .single();

    return EmployeeProfile.fromJson(response);
  } catch (e) {
    return null;
  }
});
