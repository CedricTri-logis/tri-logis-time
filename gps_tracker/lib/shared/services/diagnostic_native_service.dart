import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/diagnostic_event.dart';
import 'diagnostic_logger.dart';

/// Listens to native platform diagnostic events (iOS MetricKit, memory pressure,
/// location pauses; Android GNSS, doze, standby bucket) and routes them to
/// DiagnosticLogger.
///
/// Fire-and-forget: never crashes, never blocks.
class DiagnosticNativeService {
  static DiagnosticNativeService? _instance;
  static const _eventChannel = EventChannel('gps_tracker/diagnostic_native');
  static const _controlChannel = MethodChannel('gps_tracker/diagnostic_native/control');

  StreamSubscription<dynamic>? _subscription;

  DiagnosticNativeService._();

  static DiagnosticNativeService get instance {
    _instance ??= DiagnosticNativeService._();
    return _instance!;
  }

  /// Start listening for native diagnostic events.
  void initialize() {
    if (_subscription != null) return;

    try {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        _handleEvent,
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('[DiagNative] Stream error: $error');
          }
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DiagNative] Failed to listen: $e');
      }
    }
  }

  /// Start active monitoring (GNSS, standby bucket polling). Call when shift starts.
  Future<void> startMonitoring() async {
    if (!Platform.isAndroid) return;
    try {
      await _controlChannel.invokeMethod('startMonitoring');
    } catch (_) {}
  }

  /// Stop active monitoring. Call when shift ends.
  Future<void> stopMonitoring() async {
    if (!Platform.isAndroid) return;
    try {
      await _controlChannel.invokeMethod('stopMonitoring');
    } catch (_) {}
  }

  void _handleEvent(dynamic rawEvent) {
    if (!DiagnosticLogger.isInitialized) return;

    try {
      final Map<String, dynamic> event;
      if (rawEvent is String) {
        event = jsonDecode(rawEvent) as Map<String, dynamic>;
      } else if (rawEvent is Map) {
        event = Map<String, dynamic>.from(rawEvent);
      } else {
        return;
      }

      final type = event['type'] as String?;
      if (type == null) return;

      final logger = DiagnosticLogger.instance;

      switch (type) {
        // iOS: CLLocationManager paused updates
        case 'location_paused':
          logger.gps(
            Severity.warn,
            'iOS location updates paused by system',
          );

        // iOS: CLLocationManager resumed updates
        case 'location_resumed':
          logger.gps(
            Severity.info,
            'iOS location updates resumed',
          );

        // iOS: Memory pressure
        case 'memory_pressure':
          final level = event['level'] as String? ?? 'unknown';
          logger.memory(
            level == 'critical' ? Severity.critical : Severity.warn,
            'Memory pressure: $level',
            metadata: {'level': level},
          );

        // Android: GNSS satellite status
        case 'gnss_status':
          final satCount = event['satellite_count'] as int? ?? 0;
          logger.log(
            category: EventCategory.satellite,
            severity: satCount < 4 ? Severity.warn : Severity.info,
            message: 'GNSS status: $satCount satellites',
            metadata: {
              'satellite_count': satCount,
              if (event['avg_cn0'] != null) 'avg_cn0': event['avg_cn0'],
              if (event['ttff_ms'] != null) 'ttff_ms': event['ttff_ms'],
            },
          );

        // Android: Doze mode change
        case 'doze_changed':
          final isIdle = event['is_idle'] as bool? ?? false;
          logger.log(
            category: EventCategory.doze,
            severity: isIdle ? Severity.warn : Severity.info,
            message: isIdle ? 'Device entered doze mode' : 'Device exited doze mode',
            metadata: {'is_idle': isIdle},
          );

        // Android: Standby bucket change
        case 'standby_bucket_changed':
          final bucketName = event['bucket_name'] as String? ?? 'UNKNOWN';
          final isRestricted = bucketName == 'RARE' || bucketName == 'RESTRICTED';
          logger.service(
            isRestricted ? Severity.warn : Severity.info,
            'App standby bucket: $bucketName',
            metadata: {
              'bucket': event['bucket'],
              'bucket_name': bucketName,
            },
          );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DiagNative] Event handling error: $e');
      }
    }
  }

  /// Dispose the service.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
