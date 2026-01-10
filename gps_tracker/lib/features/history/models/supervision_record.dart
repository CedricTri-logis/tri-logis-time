import 'package:flutter/foundation.dart';

/// Represents a manager-employee supervision relationship
@immutable
class SupervisionRecord {
  final String id;
  final String managerId;
  final String employeeId;
  final SupervisionType type;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final DateTime createdAt;

  const SupervisionRecord({
    required this.id,
    required this.managerId,
    required this.employeeId,
    required this.type,
    required this.effectiveFrom,
    this.effectiveTo,
    required this.createdAt,
  });

  /// Whether this supervision is currently active
  bool get isActive =>
      effectiveTo == null || effectiveTo!.isAfter(DateTime.now());

  factory SupervisionRecord.fromJson(Map<String, dynamic> json) {
    return SupervisionRecord(
      id: json['id'] as String,
      managerId: json['manager_id'] as String,
      employeeId: json['employee_id'] as String,
      type: SupervisionType.fromString(json['supervision_type'] as String),
      effectiveFrom: DateTime.parse(json['effective_from'] as String),
      effectiveTo: json['effective_to'] != null
          ? DateTime.parse(json['effective_to'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'manager_id': managerId,
        'employee_id': employeeId,
        'supervision_type': type.value,
        'effective_from': effectiveFrom.toIso8601String(),
        'effective_to': effectiveTo?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SupervisionRecord &&
        other.id == id &&
        other.managerId == managerId &&
        other.employeeId == employeeId &&
        other.type == type &&
        other.effectiveFrom == effectiveFrom &&
        other.effectiveTo == effectiveTo &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      managerId,
      employeeId,
      type,
      effectiveFrom,
      effectiveTo,
      createdAt,
    );
  }

  @override
  String toString() {
    return 'SupervisionRecord(id: $id, managerId: $managerId, employeeId: $employeeId, type: ${type.value}, isActive: $isActive)';
  }
}

/// Type of supervision relationship
enum SupervisionType {
  /// Primary/direct supervisor
  direct('direct'),

  /// Secondary/matrix supervisor
  matrix('matrix'),

  /// Temporary supervision (e.g., covering for another manager)
  temporary('temporary');

  final String value;
  const SupervisionType(this.value);

  static SupervisionType fromString(String value) {
    return SupervisionType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => SupervisionType.direct,
    );
  }
}
