import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/user_role.dart';
import '../models/user_with_role.dart';

/// Service for admin operations including user and role management.
///
/// Provides methods for:
/// - Fetching all users (admin/super_admin only)
/// - Updating user roles
class AdminService {
  final SupabaseClient _supabase;

  AdminService(this._supabase);

  /// Get all users in the system.
  ///
  /// Only accessible by admin and super_admin roles.
  /// Returns users sorted by role (super_admin first) then by name.
  Future<List<UserWithRole>> getAllUsers() async {
    final response = await _supabase.rpc('get_all_users');

    if (response == null) {
      throw const AdminException('No response from get_all_users');
    }

    return (response as List<dynamic>)
        .map((json) => UserWithRole.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Update a user's role.
  ///
  /// Only admin and super_admin can call this.
  /// - Cannot modify super_admin role
  /// - Only super_admin can assign super_admin role
  /// - Cannot change own role (unless super_admin)
  Future<void> updateUserRole({
    required String userId,
    required UserRole newRole,
  }) async {
    final response = await _supabase.rpc(
      'update_user_role',
      params: {
        'p_user_id': userId,
        'p_new_role': newRole.value,
      },
    );

    if (response == null) {
      throw const AdminException('No response from update_user_role');
    }

    if (response == false) {
      throw const AdminException('Failed to update user role');
    }
  }

  /// Check if current user can modify the target user's role.
  ///
  /// Returns false if:
  /// - Target user is super_admin (protected)
  /// - Current user is not admin/super_admin
  bool canModifyUserRole({
    required UserRole targetRole,
    required UserRole currentUserRole,
    required String targetUserId,
    required String currentUserId,
  }) {
    // Cannot modify super_admin
    if (targetRole.isSuperAdmin) {
      return false;
    }

    // Only admin/super_admin can modify roles
    if (!currentUserRole.canManageRoles) {
      return false;
    }

    // Cannot modify own role (unless super_admin)
    if (targetUserId == currentUserId && !currentUserRole.isSuperAdmin) {
      return false;
    }

    return true;
  }

  /// Get available roles that current user can assign.
  ///
  /// Only super_admin can assign super_admin role.
  List<UserRole> getAssignableRoles(UserRole currentUserRole) {
    if (currentUserRole.isSuperAdmin) {
      return UserRole.values;
    }

    // Regular admin can assign all roles except super_admin
    return UserRole.values
        .where((role) => role != UserRole.superAdmin)
        .toList();
  }
}

/// Exception thrown by admin service operations.
class AdminException implements Exception {
  final String message;

  const AdminException(this.message);

  @override
  String toString() => 'AdminException: $message';
}
