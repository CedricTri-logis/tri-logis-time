import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/tracking/services/android_battery_health_service.dart';

/// Reports device permissions and info to Supabase at clock-in.
class DeviceStatusService {
  static final _deviceInfo = DeviceInfoPlugin();

  /// Collect all device status and send to server.
  /// Fire-and-forget — errors are silently logged.
  static Future<void> reportStatus() async {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) return;

      final results = await Future.wait([
        _checkNotificationsEnabled(),
        _getGpsPermission(),
        _checkPreciseLocation(),
        _checkBatteryOptimization(),
        _getDeviceInfo(),
      ]);

      final notificationsEnabled = results[0] as bool;
      final gpsPermission = results[1] as String;
      final preciseLocation = results[2] as bool;
      final batteryOptDisabled = results[3] as bool;
      final deviceInfo = results[4] as Map<String, String>;

      await client.rpc<dynamic>('upsert_device_status', params: {
        'p_notifications_enabled': notificationsEnabled,
        'p_gps_permission': gpsPermission,
        'p_precise_location_enabled': preciseLocation,
        'p_battery_optimization_disabled': batteryOptDisabled,
        'p_app_version': deviceInfo['app_version'],
        'p_device_model': deviceInfo['device_model'],
        'p_os_version': deviceInfo['os_version'],
        'p_platform': deviceInfo['platform'],
      },);
    } catch (e) {
      debugPrint('[DeviceStatusService] Failed to report status: $e');
    }
  }

  static Future<bool> _checkNotificationsEnabled() async {
    try {
      if (Platform.isAndroid) {
        final result =
            await FlutterForegroundTask.checkNotificationPermission();
        return result == NotificationPermission.granted;
      }
      if (Platform.isIOS) {
        final plugin = FlutterLocalNotificationsPlugin();
        final iosPlugin = plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final granted = await iosPlugin?.checkPermissions();
        return granted?.isEnabled ?? false;
      }
      return false;
    } catch (e) {
      debugPrint('[DeviceStatusService] Notification check failed: $e');
      return false;
    }
  }

  static Future<String> _getGpsPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      return switch (permission) {
        LocationPermission.always => 'always',
        LocationPermission.whileInUse => 'whileInUse',
        LocationPermission.deniedForever => 'deniedForever',
        _ => 'denied',
      };
    } catch (e) {
      return 'unknown';
    }
  }

  static Future<bool> _checkPreciseLocation() async {
    if (Platform.isIOS) return true;
    try {
      final accuracy = await Geolocator.getLocationAccuracy();
      return accuracy == LocationAccuracyStatus.precise;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> _checkBatteryOptimization() async {
    if (Platform.isIOS) return true;
    try {
      return await AndroidBatteryHealthService.isBatteryOptimizationDisabled;
    } catch (_) {
      return true;
    }
  }

  static Future<Map<String, String>> _getDeviceInfo() async {
    String platform;
    String osVersion;
    String model;

    if (Platform.isAndroid) {
      final android = await _deviceInfo.androidInfo;
      platform = 'android';
      osVersion =
          'Android ${android.version.release} (SDK ${android.version.sdkInt})';
      model = '${android.manufacturer} ${android.model}';
    } else if (Platform.isIOS) {
      final ios = await _deviceInfo.iosInfo;
      platform = 'ios';
      osVersion = '${ios.systemName} ${ios.systemVersion}';
      model = ios.utsname.machine;
    } else {
      platform = Platform.operatingSystem;
      osVersion = Platform.operatingSystemVersion;
      model = 'unknown';
    }

    String appVersion;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      appVersion = 'unknown';
    }

    return {
      'platform': platform,
      'os_version': osVersion,
      'device_model': model,
      'app_version': appVersion,
    };
  }
}
