import 'dart:io';
import 'package:flutter/services.dart';

/// Checks iOS-specific device settings that affect background GPS tracking.
/// All methods return false on Android (not applicable).
class IosDeviceChecksService {
  static const _channel = MethodChannel('gps_tracker/background_execution');

  /// Returns true if iOS Low Power Mode is enabled.
  /// Low Power Mode throttles background GPS updates significantly.
  static Future<bool> isLowPowerModeEnabled() async {
    if (!Platform.isIOS) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isLowPowerModeEnabled');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if Background App Refresh is enabled for this app.
  /// When disabled, iOS aggressively kills background processes.
  static Future<bool> isBackgroundAppRefreshEnabled() async {
    if (!Platform.isIOS) return true; // Not applicable on Android
    try {
      final result = await _channel.invokeMethod<bool>('isBackgroundAppRefreshEnabled');
      return result ?? true;
    } catch (_) {
      return true; // Fail-open
    }
  }
}
