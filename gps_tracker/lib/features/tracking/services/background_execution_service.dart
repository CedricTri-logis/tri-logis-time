import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Static utility class wrapping the iOS background execution method channel.
///
/// Provides access to:
/// - CLBackgroundActivitySession (iOS 17+) — declares legitimate continuous
///   background location activity.
/// - UIApplication.beginBackgroundTask — requests ~30s of additional execution
///   time during foreground-to-background transition.
///
/// All methods are no-ops on Android. All calls are fail-open (errors logged,
/// never crash tracking).
class BackgroundExecutionService {
  static const _channel = MethodChannel('gps_tracker/background_execution');
  static bool _callbackRegistered = false;

  /// Start a CLBackgroundActivitySession (iOS 17+, no-op on older/Android).
  static Future<void> startBackgroundSession() async {
    if (!Platform.isIOS) return;
    _ensureCallbackRegistered();

    try {
      await _channel.invokeMethod<bool>('startBackgroundSession');
      debugPrint('[BackgroundExecution] Background session started');
    } catch (e) {
      debugPrint('[BackgroundExecution] Failed to start session: $e');
    }
  }

  /// Stop the CLBackgroundActivitySession.
  static Future<void> stopBackgroundSession() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('stopBackgroundSession');
      debugPrint('[BackgroundExecution] Background session stopped');
    } catch (e) {
      debugPrint('[BackgroundExecution] Failed to stop session: $e');
    }
  }

  /// Check if a background session is currently active.
  static Future<bool> isBackgroundSessionActive() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isBackgroundSessionActive');
      return result ?? false;
    } catch (e) {
      debugPrint('[BackgroundExecution] Failed to check session: $e');
      return false;
    }
  }

  /// Request ~30s of additional execution time from iOS (belt-and-suspenders).
  static Future<void> beginBackgroundTask({String? name}) async {
    if (!Platform.isIOS) return;
    _ensureCallbackRegistered();

    try {
      await _channel.invokeMethod<bool>('beginBackgroundTask', {
        if (name != null) 'name': name,
      });
      debugPrint('[BackgroundExecution] Background task started');
    } catch (e) {
      debugPrint('[BackgroundExecution] Failed to begin task: $e');
    }
  }

  /// End the current background task.
  static Future<void> endBackgroundTask() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('endBackgroundTask');
      debugPrint('[BackgroundExecution] Background task ended');
    } catch (e) {
      debugPrint('[BackgroundExecution] Failed to end task: $e');
    }
  }

  /// Register callback handler for native → Flutter calls.
  static void _ensureCallbackRegistered() {
    if (_callbackRegistered) return;
    _channel.setMethodCallHandler(_handleMethodCall);
    _callbackRegistered = true;
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onBackgroundTaskExpired':
        debugPrint('[BackgroundExecution] iOS background task expired');
    }
  }
}
