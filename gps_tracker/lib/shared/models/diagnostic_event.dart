import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Categories for diagnostic events.
enum EventCategory {
  gps,
  shift,
  sync,
  auth,
  permission,
  lifecycle,
  thermal,
  error,
  network;

  String get value => name;
}

/// Severity levels for diagnostic events.
enum Severity {
  debug,
  info,
  warn,
  error,
  critical;

  String get value => name;

  /// Whether this severity should be synced to the server.
  /// Debug events are local-only.
  bool get shouldSync => this != debug;
}

/// A single diagnostic event captured on the device.
class DiagnosticEvent {
  final String id;
  final String employeeId;
  final String? shiftId;
  final String deviceId;
  final EventCategory eventCategory;
  final Severity severity;
  final String message;
  final Map<String, dynamic>? metadata;
  final String appVersion;
  final String platform;
  final String? osVersion;
  final String syncStatus;
  final DateTime createdAt;

  DiagnosticEvent({
    required this.id,
    required this.employeeId,
    this.shiftId,
    required this.deviceId,
    required this.eventCategory,
    required this.severity,
    required this.message,
    this.metadata,
    required this.appVersion,
    required this.platform,
    this.osVersion,
    this.syncStatus = 'pending',
    required this.createdAt,
  });

  /// Create a new event with auto-generated UUID and current timestamp.
  factory DiagnosticEvent.create({
    required String employeeId,
    String? shiftId,
    required String deviceId,
    required EventCategory eventCategory,
    required Severity severity,
    required String message,
    Map<String, dynamic>? metadata,
    required String appVersion,
    required String platform,
    String? osVersion,
  }) {
    return DiagnosticEvent(
      id: const Uuid().v4(),
      employeeId: employeeId,
      shiftId: shiftId,
      deviceId: deviceId,
      eventCategory: eventCategory,
      severity: severity,
      message: message,
      metadata: metadata,
      appVersion: appVersion,
      platform: platform,
      osVersion: osVersion,
      createdAt: DateTime.now().toUtc(),
    );
  }

  /// Convert to SQLite map for local storage.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employee_id': employeeId,
      'shift_id': shiftId,
      'device_id': deviceId,
      'event_category': eventCategory.value,
      'severity': severity.value,
      'message': message,
      'metadata': metadata != null ? jsonEncode(metadata) : null,
      'app_version': appVersion,
      'platform': platform,
      'os_version': osVersion,
      'sync_status': syncStatus,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Create from SQLite map.
  factory DiagnosticEvent.fromMap(Map<String, dynamic> map) {
    return DiagnosticEvent(
      id: map['id'] as String,
      employeeId: map['employee_id'] as String,
      shiftId: map['shift_id'] as String?,
      deviceId: map['device_id'] as String,
      eventCategory: EventCategory.values.firstWhere(
        (e) => e.value == map['event_category'],
      ),
      severity: Severity.values.firstWhere(
        (e) => e.value == map['severity'],
      ),
      message: map['message'] as String,
      metadata: map['metadata'] != null
          ? jsonDecode(map['metadata'] as String) as Map<String, dynamic>
          : null,
      appVersion: map['app_version'] as String,
      platform: map['platform'] as String,
      osVersion: map['os_version'] as String?,
      syncStatus: map['sync_status'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Convert to JSON for the sync_diagnostic_logs RPC.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'employee_id': employeeId,
      'shift_id': shiftId,
      'device_id': deviceId,
      'event_category': eventCategory.value,
      'severity': severity.value,
      'message': message,
      'metadata': metadata,
      'app_version': appVersion,
      'platform': platform,
      'os_version': osVersion,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
