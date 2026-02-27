import 'package:flutter/foundation.dart';

enum CarpoolRole {
  driver,
  passenger,
  unassigned;

  factory CarpoolRole.fromJson(String value) {
    switch (value) {
      case 'driver':
        return CarpoolRole.driver;
      case 'passenger':
        return CarpoolRole.passenger;
      default:
        return CarpoolRole.unassigned;
    }
  }

  String get displayName {
    switch (this) {
      case CarpoolRole.driver:
        return 'Conducteur';
      case CarpoolRole.passenger:
        return 'Passager';
      case CarpoolRole.unassigned:
        return 'Non assigné';
    }
  }
}

@immutable
class CarpoolMemberInfo {
  final String employeeId;
  final String employeeName;
  final CarpoolRole role;

  const CarpoolMemberInfo({
    required this.employeeId,
    required this.employeeName,
    required this.role,
  });
}

/// Lightweight carpool info attached to a Trip for display purposes.
@immutable
class CarpoolInfo {
  final String groupId;
  final CarpoolRole myRole;
  final String? driverName;
  final List<CarpoolMemberInfo> members;

  const CarpoolInfo({
    required this.groupId,
    required this.myRole,
    this.driverName,
    this.members = const [],
  });

  bool get isPassenger => myRole == CarpoolRole.passenger;
  bool get isDriver => myRole == CarpoolRole.driver;
}
