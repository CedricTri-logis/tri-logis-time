import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for iOS Significant Location Change monitoring.
///
/// Uses cell tower triangulation (not GPS) to detect ~500m+ movements.
/// Critical feature: iOS relaunches the app even after termination.
/// This is a safety net — not a replacement for continuous GPS tracking.
///
/// On Android, this is a no-op (Android foreground service handles everything).
class SignificantLocationService {
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
      debugPrint('[SignificantLocation] Monitoring started');
    } catch (e) {
      debugPrint('[SignificantLocation] Failed to start: $e');
    }
  }

  /// Stop monitoring significant location changes.
  static Future<void> stopMonitoring() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('stopMonitoring');
      debugPrint('[SignificantLocation] Monitoring stopped');
    } catch (e) {
      debugPrint('[SignificantLocation] Failed to stop: $e');
    }
  }

  /// Handle method calls from native iOS.
  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onSignificantLocationChange') {
      debugPrint('[SignificantLocation] Woken by location change: '
          '${call.arguments}');
      onWokenByLocationChange?.call();
    }
  }
}
