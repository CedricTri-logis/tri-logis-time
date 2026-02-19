import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_id_service.dart';

/// Checks whether this device is still the active session.
///
/// Fail-open: returns `true` on any error (network, offline, etc.)
/// so offline workers aren't locked out.
class DeviceSessionService {
  final SupabaseClient _client;

  DeviceSessionService(this._client);

  /// Returns `true` if this device is still the active session,
  /// or if the check cannot be performed (fail-open).
  Future<bool> isDeviceSessionActive() async {
    try {
      final deviceId = await DeviceIdService.getDeviceId();
      final result = await _client.rpc<dynamic>('check_device_session', params: {
        'p_device_id': deviceId,
      },);

      if (result is Map<String, dynamic>) {
        return result['is_active'] as bool? ?? true;
      }
      // Unexpected response — fail-open
      return true;
    } catch (e) {
      debugPrint('DeviceSessionService: check failed (fail-open): $e');
      return true;
    }
  }
}
