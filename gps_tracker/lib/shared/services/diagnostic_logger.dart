import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/diagnostic_event.dart';
import 'local_database.dart';

/// Centralized diagnostic logging service.
///
/// Persists structured events locally (SQLCipher) and outputs to console in debug mode.
/// Events are synced to the server by [DiagnosticSyncService] piggybacking on the existing sync cycle.
///
/// Usage:
/// ```dart
/// DiagnosticLogger.instance.gps(Severity.warn, 'GPS signal lost', metadata: {...});
/// ```
class DiagnosticLogger {
  static DiagnosticLogger? _instance;

  final LocalDatabase _localDb;
  String? _employeeId;
  String? _shiftId;
  String _deviceId;
  late String _appVersion;
  late String _platform;
  String? _osVersion;

  bool _initialized = false;

  DiagnosticLogger._({
    required LocalDatabase localDb,
    required String deviceId,
  })  : _localDb = localDb,
        _deviceId = deviceId;

  /// Get the singleton instance. Must call [initialize] first.
  static DiagnosticLogger get instance {
    assert(_instance != null, 'DiagnosticLogger not initialized. Call initialize() first.');
    return _instance!;
  }

  /// Whether the logger has been initialized.
  static bool get isInitialized => _instance?._initialized ?? false;

  /// Initialize the diagnostic logger singleton.
  static Future<DiagnosticLogger> initialize({
    required LocalDatabase localDb,
    required String deviceId,
    String? employeeId,
  }) async {
    final logger = DiagnosticLogger._(localDb: localDb, deviceId: deviceId);
    logger._employeeId = employeeId;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      logger._appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      logger._appVersion = 'unknown';
    }

    logger._platform = Platform.isIOS ? 'ios' : 'android';

    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        logger._osVersion = '${ios.systemName} ${ios.systemVersion}';
      } else {
        final android = await deviceInfo.androidInfo;
        logger._osVersion = 'Android ${android.version.release} (SDK ${android.version.sdkInt})';
      }
    } catch (_) {
      // Best-effort
    }

    logger._initialized = true;
    _instance = logger;
    return logger;
  }

  /// Update the active employee ID (on sign-in/sign-out).
  void setEmployeeId(String? employeeId) {
    _employeeId = employeeId;
  }

  /// Update the active shift ID (on clock-in/clock-out).
  void setShiftId(String? shiftId) {
    _shiftId = shiftId;
  }

  /// Update the device ID.
  void setDeviceId(String deviceId) {
    _deviceId = deviceId;
  }

  /// Log a diagnostic event.
  ///
  /// This is async fire-and-forget — it never blocks callers and never throws.
  Future<void> log({
    required EventCategory category,
    required Severity severity,
    required String message,
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_initialized) return;

    final employeeId = _employeeId;
    if (employeeId == null) return;

    // Always output to console in debug mode
    if (kDebugMode) {
      debugPrint('[Diag:${category.value}:${severity.value}] $message');
    }

    try {
      final event = DiagnosticEvent.create(
        employeeId: employeeId,
        shiftId: shiftId ?? _shiftId,
        deviceId: _deviceId,
        eventCategory: category,
        severity: severity,
        message: message,
        metadata: metadata,
        appVersion: _appVersion,
        platform: _platform,
        osVersion: _osVersion,
      );

      await _localDb.insertDiagnosticEvent(event);
    } catch (_) {
      // Never crash for logging
    }
  }

  // ---- Convenience methods per category ----

  Future<void> gps(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.gps, severity: severity, message: message, shiftId: shiftId, metadata: metadata);

  Future<void> shift(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.shift, severity: severity, message: message, shiftId: shiftId, metadata: metadata);

  Future<void> sync(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.sync, severity: severity, message: message, shiftId: shiftId, metadata: metadata);

  Future<void> auth(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.auth, severity: severity, message: message, metadata: metadata);

  Future<void> thermal(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.thermal, severity: severity, message: message, shiftId: shiftId, metadata: metadata);

  Future<void> lifecycle(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.lifecycle, severity: severity, message: message, metadata: metadata);

  Future<void> network(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.network, severity: severity, message: message, metadata: metadata);

  Future<void> permission(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.permission, severity: severity, message: message, metadata: metadata);
}
