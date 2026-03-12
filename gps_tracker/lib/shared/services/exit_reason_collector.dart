import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/diagnostic_event.dart';
import 'local_database.dart';

/// Collects OS exit reasons on app launch and stores them as DiagnosticEvents.
///
/// Android: reads ApplicationExitInfo (API 30+) — per-event with timestamps.
/// iOS: reads MetricKit MXAppExitMetric (iOS 14+) — cumulative delta counts.
///
/// Bypasses DiagnosticLogger (which requires non-null employeeId) and inserts
/// directly into LocalDatabase. The deviceId is used as a temporary employee_id;
/// DiagnosticSyncService replaces it with auth.uid() at sync time.
///
/// Fire-and-forget: never blocks app startup, never throws.
class ExitReasonCollector {
  static const _channel = MethodChannel('gps_tracker/exit_reason');

  /// Collect exit reasons from the OS and store as diagnostic events.
  /// Call once at app launch, after LocalDatabase is initialized.
  static Future<void> collect(LocalDatabase localDb, String deviceId) async {
    try {
      if (Platform.isAndroid) {
        await _collectAndroid(localDb, deviceId);
      } else if (Platform.isIOS) {
        await _collectIOS(localDb, deviceId);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ExitReasonCollector] Failed to collect: $e');
      }
    }
  }

  /// Update the process state summary (Android only).
  /// Called periodically during an active shift.
  static Future<void> updateProcessState(Map<String, dynamic> state) async {
    if (!Platform.isAndroid) return;

    try {
      final jsonString = jsonEncode(state);
      await _channel.invokeMethod('updateProcessState', {'state': jsonString});
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ExitReasonCollector] Failed to update process state: $e');
      }
    }
  }

  static Future<void> _collectAndroid(LocalDatabase localDb, String deviceId) async {
    final results = await _channel.invokeMethod<List<dynamic>>('getExitReasons');
    if (results == null || results.isEmpty) return;

    final appVersion = await _getAppVersion();
    final osVersion = await _getOsVersion();

    for (final raw in results) {
      final info = Map<String, dynamic>.from(raw as Map);
      final reason = info['reason'] as String? ?? 'unknown';
      final reasonCode = info['reason_code'] as int? ?? 0;
      final pssKb = info['pss_kb'] as int? ?? 0;
      final importance = info['importance'] as String? ?? 'unknown';
      final description = info['description'] as String? ?? '';
      final timestamp = info['timestamp'] as int? ?? 0;

      final severity = _severityForReason(reason);
      final pssMb = pssKb > 0 ? '${(pssKb / 1024).toStringAsFixed(0)}MB' : 'N/A';

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId, // Temporary — replaced at sync time
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: severity,
        message: 'App killed: $reason, PSS=$pssMb, importance=$importance',
        metadata: {
          'reason': reason,
          'reason_code': reasonCode,
          'exit_timestamp': timestamp,
          'description': description,
          'importance': importance,
          'importance_code': info['importance_code'],
          'pss_kb': pssKb,
          'rss_kb': info['rss_kb'],
          'status': info['status'],
          'process_state_summary': info['process_state_summary'],
        },
        appVersion: appVersion,
        platform: 'android',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    if (kDebugMode) {
      debugPrint('[ExitReasonCollector] Collected ${results.length} Android exit reasons');
    }
  }

  static Future<void> _collectIOS(LocalDatabase localDb, String deviceId) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getExitMetrics');
    if (result == null) return;

    final data = Map<String, dynamic>.from(result);
    final foreground = data['foreground'] as Map? ?? {};
    final background = data['background'] as Map? ?? {};
    final crashes = data['crashes'] as List? ?? [];

    final appVersion = await _getAppVersion();
    final osVersion = await _getOsVersion();

    // Check if there are any non-zero deltas
    final hasForegroundExits = foreground.values.any((v) => v is int && v > 0);
    final hasBackgroundExits = background.values.any((v) => v is int && v > 0);

    if (hasForegroundExits || hasBackgroundExits) {
      // Create one summary event with all exit count deltas
      final severity = _iosExitSeverity(foreground, background);

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId,
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: severity,
        message: _iosExitMessage(foreground, background),
        metadata: {
          'foreground': Map<String, dynamic>.from(foreground),
          'background': Map<String, dynamic>.from(background),
          if (data['period_start'] != null) 'period_start': data['period_start'],
          if (data['period_end'] != null) 'period_end': data['period_end'],
        },
        appVersion: appVersion,
        platform: 'ios',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    // Create separate events for each crash diagnostic
    for (final crash in crashes) {
      final crashData = Map<String, dynamic>.from(crash as Map);

      final event = DiagnosticEvent(
        id: const Uuid().v4(),
        employeeId: deviceId,
        deviceId: deviceId,
        eventCategory: EventCategory.exitInfo,
        severity: Severity.critical,
        message: 'MetricKit crash diagnostic',
        metadata: crashData,
        appVersion: appVersion,
        platform: 'ios',
        osVersion: osVersion,
        createdAt: DateTime.now().toUtc(),
      );

      await localDb.insertDiagnosticEvent(event);
    }

    if (kDebugMode) {
      final count = (hasForegroundExits || hasBackgroundExits ? 1 : 0) + crashes.length;
      if (count > 0) {
        debugPrint('[ExitReasonCollector] Collected $count iOS exit metric events');
      }
    }
  }

  /// Map Android exit reason to severity.
  static Severity _severityForReason(String reason) {
    switch (reason) {
      case 'low_memory':
      case 'crash':
      case 'crash_native':
      case 'anr':
      case 'excessive_resource_usage':
      case 'initialization_failure':
        return Severity.critical;
      case 'user_requested':
      case 'user_stopped':
      case 'freezer':
      case 'signaled':
        return Severity.warn;
      case 'exit_self':
      case 'other':
      case 'permission_change':
      case 'dependency_died':
      case 'package_state_change':
      case 'package_updated':
        return Severity.info;
      default:
        return Severity.warn;
    }
  }

  /// Determine severity from iOS exit count deltas.
  static Severity _iosExitSeverity(Map<dynamic, dynamic> foreground, Map<dynamic, dynamic> background) {
    final criticalKeys = [
      'memory_limit', 'memory_pressure', 'watchdog', 'cpu_limit',
      'bad_access', 'illegal_instruction', 'abnormal', 'background_task_timeout',
    ];
    for (final key in criticalKeys) {
      if ((foreground[key] as int? ?? 0) > 0) return Severity.critical;
      if ((background[key] as int? ?? 0) > 0) return Severity.critical;
    }
    return Severity.info;
  }

  /// Build human-readable message from iOS exit deltas.
  static String _iosExitMessage(Map<dynamic, dynamic> foreground, Map<dynamic, dynamic> background) {
    final parts = <String>[];
    foreground.forEach((key, value) {
      if (value is int && value > 0) parts.add('fg_$key=$value');
    });
    background.forEach((key, value) {
      if (value is int && value > 0) parts.add('bg_$key=$value');
    });
    return parts.isEmpty ? 'iOS exit metrics (no deltas)' : 'iOS exits: ${parts.join(', ')}';
  }

  static Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  static Future<String?> _getOsVersion() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        return '${ios.systemName} ${ios.systemVersion}';
      } else {
        final android = await deviceInfo.androidInfo;
        return 'Android ${android.version.release} (SDK ${android.version.sdkInt})';
      }
    } catch (_) {
      return null;
    }
  }
}
