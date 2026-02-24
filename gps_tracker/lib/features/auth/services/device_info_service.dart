import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_id_service.dart';

/// Captures and syncs device info via register_device_login RPC.
class DeviceInfoService {
  final SupabaseClient _client;
  static final _deviceInfo = DeviceInfoPlugin();

  DeviceInfoService(this._client);

  /// Register this device and sync info via RPC.
  /// Fire-and-forget — errors are silently ignored.
  Future<void> syncDeviceInfo() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final info = await _getDeviceInfo();
      final deviceId = await DeviceIdService.getDeviceId();

      await _client.rpc<dynamic>('register_device_login', params: {
        'p_device_id': deviceId,
        'p_device_platform': info['device_platform'],
        'p_device_os_version': info['device_os_version'],
        'p_device_model': info['device_model'],
        'p_app_version': info['device_app_version'],
      },);
    } catch (e) {
      debugPrint('DeviceInfoService: failed to sync device info: $e');
    }
  }

  static Future<Map<String, String>> _getDeviceInfo() async {
    String platform;
    String osVersion;
    String model;

    if (Platform.isAndroid) {
      final android = await _deviceInfo.androidInfo;
      platform = 'android';
      osVersion = 'Android ${android.version.release} (SDK ${android.version.sdkInt})';
      model = '${android.manufacturer} ${android.model}';
    } else if (Platform.isIOS) {
      final ios = await _deviceInfo.iosInfo;
      platform = 'ios';
      osVersion = '${ios.systemName} ${ios.systemVersion}';
      model = ios.utsname.machine; // e.g. iPhone15,2
    } else {
      platform = Platform.operatingSystem;
      osVersion = Platform.operatingSystemVersion;
      model = 'unknown';
    }

    // Read version dynamically from package info
    String appVersion;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      appVersion = 'unknown';
    }

    return {
      'device_platform': platform,
      'device_os_version': osVersion,
      'device_model': model,
      'device_app_version': appVersion,
    };
  }
}
