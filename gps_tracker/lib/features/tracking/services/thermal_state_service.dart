import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thermal pressure level for GPS frequency adaptation.
enum ThermalLevel {
  /// No adaptation needed.
  normal,

  /// Moderate thermal pressure — reduce GPS frequency.
  elevated,

  /// Severe thermal pressure — minimum GPS frequency.
  critical,
}

/// Cross-platform service monitoring device thermal state.
///
/// iOS: Uses ProcessInfo.thermalState via NotificationCenter observer.
/// Android: Uses PowerManager thermal status (API 29+) via EventChannel.
///
/// Fail-open: any error returns ThermalLevel.normal.
class ThermalStateService {
  static const _methodChannel = MethodChannel('gps_tracker/thermal');
  static const _eventChannel = EventChannel('gps_tracker/thermal/stream');

  static bool _callbackRegistered = false;
  static final _iosStreamController = StreamController<ThermalLevel>.broadcast();

  /// Get current thermal level (one-shot).
  static Future<ThermalLevel> getCurrentLevel() async {
    try {
      if (Platform.isIOS) {
        final state = await _methodChannel.invokeMethod<int>('getThermalState');
        return _mapIosThermalState(state ?? 0);
      } else if (Platform.isAndroid) {
        final status = await _methodChannel.invokeMethod<int>('getThermalStatus');
        return _mapAndroidThermalStatus(status ?? 0);
      }
    } catch (e) {
      debugPrint('[ThermalState] Failed to get current level: $e');
    }
    return ThermalLevel.normal;
  }

  /// Stream of thermal level changes.
  ///
  /// On unsupported platforms/versions, emits a single `normal`.
  static Stream<ThermalLevel> get levelStream {
    if (Platform.isIOS) {
      _ensureIosCallbackRegistered();
      return _iosStreamController.stream;
    } else if (Platform.isAndroid) {
      return _eventChannel
          .receiveBroadcastStream()
          .map((event) => _mapAndroidThermalStatus(event as int? ?? 0))
          .handleError((Object error) {
        debugPrint('[ThermalState] Android stream error: $error');
        return ThermalLevel.normal;
      });
    }
    return Stream.value(ThermalLevel.normal);
  }

  /// Map iOS ProcessInfo.ThermalState raw values to ThermalLevel.
  /// - 0 (.nominal), 1 (.fair) → normal
  /// - 2 (.serious) → elevated
  /// - 3 (.critical) → critical
  static ThermalLevel _mapIosThermalState(int rawValue) {
    return switch (rawValue) {
      0 || 1 => ThermalLevel.normal,
      2 => ThermalLevel.elevated,
      3 => ThermalLevel.critical,
      _ => ThermalLevel.normal,
    };
  }

  /// Map Android PowerManager thermal status to ThermalLevel.
  /// - 0 (NONE), 1 (LIGHT) → normal
  /// - 2 (MODERATE), 3 (SEVERE) → elevated
  /// - 4+ (CRITICAL, EMERGENCY, SHUTDOWN) → critical
  static ThermalLevel _mapAndroidThermalStatus(int status) {
    return switch (status) {
      0 || 1 => ThermalLevel.normal,
      2 || 3 => ThermalLevel.elevated,
      _ => status >= 4 ? ThermalLevel.critical : ThermalLevel.normal,
    };
  }

  /// Register callback handler for iOS thermal state changes (native → Flutter).
  static void _ensureIosCallbackRegistered() {
    if (_callbackRegistered) return;
    _methodChannel.setMethodCallHandler(_handleMethodCall);
    _callbackRegistered = true;
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onThermalStateChanged') {
      final rawValue = call.arguments as int? ?? 0;
      final level = _mapIosThermalState(rawValue);
      _iosStreamController.add(level);
    }
  }
}
