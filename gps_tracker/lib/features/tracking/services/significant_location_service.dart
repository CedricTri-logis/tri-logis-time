import 'dart:io';

import 'package:flutter/services.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';

/// Service for iOS Significant Location Change monitoring.
///
/// Uses cell tower triangulation (not GPS) to detect ~500m+ movements.
/// Critical feature: iOS relaunches the app even after termination.
/// This is a safety net — not a replacement for continuous GPS tracking.
///
/// On Android, this is a no-op (Android foreground service handles everything).
class SignificantLocationService {
  static DiagnosticLogger? get _logger => DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  static const _channel = MethodChannel('gps_tracker/significant_location');

  static bool _callbackRegistered = false;

  /// Callback invoked when the app is woken by a significant location change.
  static VoidCallback? onWokenByLocationChange;

  /// Start monitoring significant location changes (iOS only).
  static Future<void> startMonitoring() async {
    if (!Platform.isIOS) return;

    // Register the callback for when iOS wakes us
    if (!_callbackRegistered) {
      _channel.setMethodCallHandler(_handleMethodCall);
      _callbackRegistered = true;
    }

    try {
      await _channel.invokeMethod<bool>('startMonitoring');
      _logger?.gps(Severity.info, 'Significant location monitoring started');
    } catch (e) {
      _logger?.gps(Severity.error, 'Significant location monitoring failed to start', metadata: {'error': e.toString()});
    }
  }

  /// Stop monitoring significant location changes.
  static Future<void> stopMonitoring() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('stopMonitoring');
      _logger?.gps(Severity.info, 'Significant location monitoring stopped');
    } catch (e) {
      _logger?.gps(Severity.error, 'Significant location monitoring failed to stop', metadata: {'error': e.toString()});
    }
  }

  /// Check whether significant location monitoring is currently active (iOS only).
  static Future<bool> isMonitoring() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isMonitoring');
      return result ?? false;
    } catch (e) {
      _logger?.gps(
        Severity.warn,
        'Failed to query significant location monitoring state',
        metadata: {'error': e.toString()},
      );
      return false;
    }
  }

  /// Handle method calls from native iOS.
  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSignificantLocationChange':
        _logger?.gps(Severity.info, 'Woken by significant location change', metadata: {
          if (call.arguments != null) 'arguments': call.arguments.toString(),
        },);
        onWokenByLocationChange?.call();
      case 'onSignificantLocationMonitoringStarted':
        _logger?.gps(Severity.info, 'Significant location monitoring started (native)');
      case 'onSignificantLocationMonitoringStopped':
        _logger?.gps(Severity.info, 'Significant location monitoring stopped (native)');
      case 'onSignificantLocationMonitoringError':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        _logger?.gps(
          Severity.error,
          'Significant location monitoring error',
          metadata: args,
        );
    }
  }
}
