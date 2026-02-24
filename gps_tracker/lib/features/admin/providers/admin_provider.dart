import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/user_role.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../models/user_with_role.dart';
import '../services/admin_service.dart';

/// Provider for the AdminService.
final adminServiceProvider = Provider<AdminService>((ref) {
  return AdminService(ref.watch(supabaseClientProvider));
});

/// State class for user management.
@immutable
class UserManagementState {
  final List<UserWithRole> users;
  final String searchQuery;
  final bool isLoading;
  final String? error;
  final DateTime? lastUpdated;

  const UserManagementState({
    this.users = const [],
    this.searchQuery = '',
    this.isLoading = false,
    this.error,
    this.lastUpdated,
  });

  /// Create initial loading state.
  factory UserManagementState.loading() {
    return const UserManagementState(isLoading: true);
  }

  /// Create error state.
  factory UserManagementState.error(String message) {
    return UserManagementState(error: message);
  }

  /// Get filtered users based on search query.
  List<UserWithRole> get filteredUsers {
    if (searchQuery.isEmpty) return users;

    final query = searchQuery.toLowerCase();
    return users.where((user) {
      return user.displayName.toLowerCase().contains(query) ||
          user.email.toLowerCase().contains(query) ||
          (user.employeeId?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  /// Create copy with updated fields.
  UserManagementState copyWith({
    List<UserWithRole>? users,
    String? searchQuery,
    bool? isLoading,
    String? error,
    bool clearError = false,
    DateTime? lastUpdated,
  }) {
    return UserManagementState(
      users: users ?? this.users,
      searchQuery: searchQuery ?? this.searchQuery,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

/// Notifier for managing user management state.
class UserManagementNotifier extends StateNotifier<UserManagementState> {
  final Ref _ref;
  bool _initialized = false;

  UserManagementNotifier(this._ref) : super(UserManagementState.loading()) {
    _initialize();
  }

  /// Initialize user management.
  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    await load();
  }

  /// Load all users from API.
  Future<void> load() async {
    final userId = _ref.read(currentUserProvider)?.id;
    if (userId == null) {
      state = UserManagementState.error('Not authenticated');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(adminServiceProvider);
      final users = await service.getAllUsers();

      state = state.copyWith(
        users: users,
        lastUpdated: DateTime.now(),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Update a user's role.
  Future<bool> updateUserRole({
    required String userId,
    required UserRole newRole,
  }) async {
    try {
      final service = _ref.read(adminServiceProvider);
      await service.updateUserRole(userId: userId, newRole: newRole);

      // Update local state
      final updatedUsers = state.users.map((user) {
        if (user.id == userId) {
          return user.copyWith(role: newRole);
        }
        return user;
      }).toList();

      state = state.copyWith(users: updatedUsers);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Update search query.
  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clear search query.
  void clearSearch() {
    state = state.copyWith(searchQuery: '');
  }

  /// Refresh users list.
  Future<void> refresh() async => load();

  /// Clear error message.
  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

/// Provider for user management state.
final userManagementProvider =
    StateNotifierProvider<UserManagementNotifier, UserManagementState>((ref) {
  return UserManagementNotifier(ref);
});

/// Provider for filtered users based on search query.
final filteredUsersProvider = Provider<List<UserWithRole>>((ref) {
  final state = ref.watch(userManagementProvider);
  return state.filteredUsers;
});

/// Provider for checking if user management is loading.
final isUserManagementLoadingProvider = Provider<bool>((ref) {
  return ref.watch(userManagementProvider).isLoading;
});

/// Provider for user management error.
final userManagementErrorProvider = Provider<String?>((ref) {
  return ref.watch(userManagementProvider).error;
});

/// Provider for user management search query.
final userSearchQueryProvider = Provider<String>((ref) {
  return ref.watch(userManagementProvider).searchQuery;
});

/// Provider for getting assignable roles based on current user's role.
final assignableRolesProvider = Provider<List<UserRole>>((ref) {
  // Return all non-super_admin roles by default
  // The actual filtering should be done in the service based on the current user
  return UserRole.values.where((role) => role != UserRole.superAdmin).toList();
});
