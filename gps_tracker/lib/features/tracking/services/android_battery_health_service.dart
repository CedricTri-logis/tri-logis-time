import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class AppStandbyBucketInfo {
  final bool supported;
  final int? bucket;
  final String? bucketName;

  const AppStandbyBucketInfo({
    required this.supported,
    required this.bucket,
    required this.bucketName,
  });

  bool get isRestricted => bucketName == 'RESTRICTED' || bucketName == 'RARE';
}

class AndroidBatteryHealthService {
  AndroidBatteryHealthService._();

  static const MethodChannel _channel =
      MethodChannel('gps_tracker/device_manufacturer');

  /// Track battery optimization status between checks to detect regression.
  static const String _lastKnownBatteryOptimizationKey =
      'battery_optimization_last_known_disabled';

  static Future<bool> get isBatteryOptimizationDisabled async {
    if (!Platform.isAndroid) return true;
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    final result =
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    await saveBatteryOptimizationSnapshot();
    return result;
  }

  static Future<void> saveBatteryOptimizationSnapshot() async {
    if (!Platform.isAndroid) return;
    final isDisabled = await isBatteryOptimizationDisabled;
    await FlutterForegroundTask.saveData(
      key: _lastKnownBatteryOptimizationKey,
      value: isDisabled,
    );
  }

  /// Returns true only when optimization was previously disabled and is now enabled again.
  static Future<bool> hasLostBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return false;

    final previous = await FlutterForegroundTask.getData<bool>(
      key: _lastKnownBatteryOptimizationKey,
    );
    final current = await isBatteryOptimizationDisabled;
    await FlutterForegroundTask.saveData(
      key: _lastKnownBatteryOptimizationKey,
      value: current,
    );
    return previous == true && current == false;
  }

  static Future<String?> getManufacturer() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getManufacturer');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> openOemBatterySettings(String manufacturer) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openOemBatterySettings',
            {'manufacturer': manufacturer},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openBatteryOptimizationSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAppBatterySettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppBatterySettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openSamsungNeverSleepingList() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openSamsungNeverSleepingList',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<AppStandbyBucketInfo> getAppStandbyBucket() async {
    if (!Platform.isAndroid) {
      return const AppStandbyBucketInfo(
        supported: false,
        bucket: null,
        bucketName: null,
      );
    }

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getAppStandbyBucket');
      if (result == null) {
        return const AppStandbyBucketInfo(
          supported: false,
          bucket: null,
          bucketName: null,
        );
      }
      return AppStandbyBucketInfo(
        supported: result['supported'] == true,
        bucket: result['bucket'] as int?,
        bucketName: result['bucketName'] as String?,
      );
    } catch (_) {
      return const AppStandbyBucketInfo(
        supported: false,
        bucket: null,
        bucketName: null,
      );
    }
  }

  /// Unused app restrictions status constants (mirrors PackageManagerCompat):
  /// 0=ERROR, 1=FEATURE_NOT_AVAILABLE, 2=DISABLED,
  /// 3=API_30_BACKPORT, 4=API_30, 5=API_31
  static Future<int> getUnusedAppRestrictionsStatus() async {
    if (!Platform.isAndroid) return 1; // FEATURE_NOT_AVAILABLE on iOS
    try {
      return await _channel.invokeMethod<int>('getUnusedAppRestrictionsStatus') ?? 1;
    } catch (_) {
      return 1; // Fail open
    }
  }

  static Future<bool> openManageUnusedAppRestrictionsSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'openManageUnusedAppRestrictionsSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if unused app restrictions need user action.
  /// Status 3 (API_30_BACKPORT), 4 (API_30), 5 (API_31) = restrictions active.
  static bool unusedRestrictionsNeedAction(int status) {
    return status == 3 || status == 4 || status == 5;
  }

  /// Start the 60-second AlarmManager rescue watchdog for an active shift.
  /// No-op on iOS. Fire-and-forget.
  static Future<void> startRescueAlarms(String shiftId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(
        'startRescueAlarms',
        {'shiftId': shiftId},
      );
    } catch (_) {
      // Best-effort — WorkManager watchdog is the fallback
    }
  }

  /// Stop the AlarmManager rescue watchdog. Call when tracking ends.
  /// No-op on iOS. Fire-and-forget.
  static Future<void> stopRescueAlarms() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopRescueAlarms');
    } catch (_) {}
  }
}
