import 'package:flutter/foundation.dart';

enum WorkStatus { onShift, onLunch, offShift }

@immutable
class ColleagueStatus {
  final String id;
  final String fullName;
  final WorkStatus workStatus;
  final String? activeSessionType;
  final String? activeSessionLocation;

  const ColleagueStatus({
    required this.id,
    required this.fullName,
    required this.workStatus,
    this.activeSessionType,
    this.activeSessionLocation,
  });

  factory ColleagueStatus.fromJson(Map<String, dynamic> json) {
    return ColleagueStatus(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      workStatus: _parseWorkStatus(json['work_status'] as String),
      activeSessionType: json['active_session_type'] as String?,
      activeSessionLocation: json['active_session_location'] as String?,
    );
  }

  static WorkStatus _parseWorkStatus(String status) {
    switch (status) {
      case 'on-shift':
        return WorkStatus.onShift;
      case 'on-lunch':
        return WorkStatus.onLunch;
      default:
        return WorkStatus.offShift;
    }
  }

  String get statusLabel {
    switch (workStatus) {
      case WorkStatus.onShift:
        return 'En quart';
      case WorkStatus.onLunch:
        return 'Dîner';
      case WorkStatus.offShift:
        return 'Hors quart';
    }
  }

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
  }

  /// Human-readable session label: "Ménage — 123 Immeuble X"
  String? get sessionLabel {
    if (activeSessionType == null) return null;
    final type = switch (activeSessionType) {
      'cleaning' => 'Ménage',
      'maintenance' => 'Entretien',
      'admin' => 'Administration',
      _ => activeSessionType!,
    };
    if (activeSessionLocation != null && activeSessionType != 'admin') {
      return '$type — $activeSessionLocation';
    }
    return type;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ColleagueStatus &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          workStatus == other.workStatus &&
          activeSessionType == other.activeSessionType;

  @override
  int get hashCode => Object.hash(id, workStatus, activeSessionType);
}
