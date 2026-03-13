import 'dart:io';

import 'package:flutter/services.dart';

/// Dart bridge for iOS BGAppRefreshTask scheduling.
///
/// Schedules periodic background app refresh so iOS relaunches the app
/// even when the employee is stationary (SLC requires ~500m movement).
/// On Android this is a no-op (WorkManager watchdog handles recovery).
class BgAppRefreshService {
  static const _channel = MethodChannel('gps_tracker/bg_app_refresh');

  /// Schedule the next BGAppRefreshTask (iOS only).
  /// Call after clock-in and after each tracking restart.
  static Future<void> schedule() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('schedule');
    } catch (_) {
      // Best-effort — don't crash tracking if scheduling fails
    }
  }

  /// Cancel any pending BGAppRefreshTask (iOS only).
  /// Call after clock-out.
  static Future<void> cancel() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('cancel');
    } catch (_) {
      // Best-effort
    }
  }
}
