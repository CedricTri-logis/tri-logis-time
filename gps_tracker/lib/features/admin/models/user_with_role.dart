import 'package:flutter/foundation.dart';

import '../../../shared/models/user_role.dart';

/// Model representing a user with their role for the admin panel
@immutable
class UserWithRole {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final String status;
  final UserRole role;
  final DateTime createdAt;

  const UserWithRole({
    required this.id,
    required this.email,
    this.fullName,
    this.employeeId,
    required this.status,
    required this.role,
    required this.createdAt,
  });

  /// Whether this user is a protected super_admin
  bool get isProtected => role.isSuperAdmin;

  /// Display name (full name or email if not set)
  String get displayName => fullName ?? email;

  /// Create from JSON response
  factory UserWithRole.fromJson(Map<String, dynamic> json) {
    return UserWithRole(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      status: json['status'] as String? ?? 'active',
      role: UserRole.fromString(json['role'] as String? ?? 'employee'),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  /// Create a copy with updated role
  UserWithRole copyWith({
    String? id,
    String? email,
    String? fullName,
    String? employeeId,
    String? status,
    UserRole? role,
    DateTime? createdAt,
  }) {
    return UserWithRole(
      id: id ?? this.id,
      email: email ?? this.email,
      fullName: fullName ?? this.fullName,
      employeeId: employeeId ?? this.employeeId,
      status: status ?? this.status,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserWithRole &&
        other.id == id &&
        other.email == email &&
        other.fullName == fullName &&
        other.employeeId == employeeId &&
        other.status == status &&
        other.role == role &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      email,
      fullName,
      employeeId,
      status,
      role,
      createdAt,
    );
  }
}
