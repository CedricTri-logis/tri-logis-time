import 'package:flutter/foundation.dart';

import '../../../shared/models/user_role.dart';

export '../../../shared/models/user_role.dart';

/// Status of an employee account
enum EmployeeStatus {
  active('active'),
  inactive('inactive'),
  suspended('suspended');

  final String value;
  const EmployeeStatus(this.value);

  static EmployeeStatus fromString(String value) {
    return EmployeeStatus.values.firstWhere(
      (e) => e.value == value,
      orElse: () => EmployeeStatus.active,
    );
  }
}

/// Employee profile data model
///
/// Represents the employee_profiles table data and provides
/// serialization/deserialization support for Supabase.
@immutable
class EmployeeProfile {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final EmployeeStatus status;
  final UserRole role;
  final DateTime? privacyConsentAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const EmployeeProfile({
    required this.id,
    required this.email,
    required this.status,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.fullName,
    this.employeeId,
    this.privacyConsentAt,
  });

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) {
    return EmployeeProfile(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      status: EmployeeStatus.fromString(json['status'] as String),
      role: UserRole.fromString(json['role'] as String? ?? 'employee'),
      privacyConsentAt: json['privacy_consent_at'] != null
          ? DateTime.parse(json['privacy_consent_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'full_name': fullName,
      'employee_id': employeeId,
      'status': status.value,
      'role': role.value,
      'privacy_consent_at': privacyConsentAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  EmployeeProfile copyWith({
    String? fullName,
    String? employeeId,
    EmployeeStatus? status,
    UserRole? role,
    DateTime? privacyConsentAt,
  }) {
    return EmployeeProfile(
      id: id,
      email: email,
      fullName: fullName ?? this.fullName,
      employeeId: employeeId ?? this.employeeId,
      status: status ?? this.status,
      role: role ?? this.role,
      privacyConsentAt: privacyConsentAt ?? this.privacyConsentAt,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// Whether the user has given privacy consent
  bool get hasPrivacyConsent => privacyConsentAt != null;

  /// Whether the account is in active status
  bool get isActive => status == EmployeeStatus.active;

  /// Whether the user has manager or admin role
  bool get isManager => role.isManager;

  /// Whether the user has admin role
  bool get isAdmin => role.isAdmin;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmployeeProfile &&
        other.id == id &&
        other.email == email &&
        other.fullName == fullName &&
        other.employeeId == employeeId &&
        other.status == status &&
        other.role == role &&
        other.privacyConsentAt == privacyConsentAt &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
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
      privacyConsentAt,
      createdAt,
      updatedAt,
    );
  }

  @override
  String toString() {
    return 'EmployeeProfile(id: $id, email: $email, fullName: $fullName, status: ${status.value}, role: ${role.value})';
  }
}
