import 'dart:io';

import 'package:flutter/services.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';

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
  static DiagnosticLogger? get _logger => DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  static const _channel = MethodChannel('gps_tracker/background_execution');
  static bool _callbackRegistered = false;

  /// Start a CLBackgroundActivitySession (iOS 17+, no-op on older/Android).
  static Future<void> startBackgroundSession() async {
    if (!Platform.isIOS) return;
    _ensureCallbackRegistered();

    try {
      await _channel.invokeMethod<bool>('startBackgroundSession');
      _logger?.lifecycle(Severity.debug, 'Background session started');
    } catch (e) {
      _logger?.lifecycle(Severity.warn, 'Failed to start background session', metadata: {'error': e.toString()});
    }
  }

  /// Stop the CLBackgroundActivitySession.
  static Future<void> stopBackgroundSession() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('stopBackgroundSession');
      _logger?.lifecycle(Severity.debug, 'Background session stopped');
    } catch (e) {
      _logger?.lifecycle(Severity.warn, 'Failed to stop background session', metadata: {'error': e.toString()});
    }
  }

  /// Check if a background session is currently active.
  static Future<bool> isBackgroundSessionActive() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isBackgroundSessionActive');
      return result ?? false;
    } catch (e) {
      _logger?.lifecycle(Severity.warn, 'Failed to check background session', metadata: {'error': e.toString()});
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
      _logger?.lifecycle(Severity.debug, 'Background task started');
    } catch (e) {
      _logger?.lifecycle(Severity.warn, 'Failed to begin background task', metadata: {'error': e.toString()});
    }
  }

  /// End the current background task.
  static Future<void> endBackgroundTask() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<bool>('endBackgroundTask');
      _logger?.lifecycle(Severity.debug, 'Background task ended');
    } catch (e) {
      _logger?.lifecycle(Severity.warn, 'Failed to end background task', metadata: {'error': e.toString()});
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
        _logger?.lifecycle(Severity.warn, 'iOS background task expired');
      case 'onBackgroundSessionStarted':
        _logger?.lifecycle(Severity.info, 'iOS background session started');
      case 'onBackgroundSessionStopped':
        _logger?.lifecycle(Severity.info, 'iOS background session stopped');
      case 'onBackgroundTaskStarted':
        _logger?.lifecycle(
          Severity.info,
          'iOS background task started',
          metadata: (call.arguments as Map?)?.cast<String, dynamic>(),
        );
      case 'onBackgroundTaskEnded':
        _logger?.lifecycle(
          Severity.info,
          'iOS background task ended',
          metadata: (call.arguments as Map?)?.cast<String, dynamic>(),
        );
      case 'onBackgroundExecutionError':
        _logger?.lifecycle(
          Severity.error,
          'iOS background execution error',
          metadata: (call.arguments as Map?)?.cast<String, dynamic>(),
        );
    }
  }
}
