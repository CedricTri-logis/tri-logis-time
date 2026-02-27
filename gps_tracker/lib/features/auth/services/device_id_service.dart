import 'package:uuid/uuid.dart';

import '../../../shared/services/secure_storage.dart';

/// Provides a persistent unique device identifier.
///
/// Uses flutter_secure_storage (iOS Keychain / Android EncryptedSharedPreferences)
/// so the ID persists across app reinstalls on most devices.
class DeviceIdService {
  static const _key = 'persistent_device_id';
  static String? _cachedId;

  /// Get the persistent device ID, creating one if it doesn't exist.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    var id = await secureStorage.read(key: _key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await secureStorage.write(key: _key, value: id);
    }

    _cachedId = id;
    return id;
  }
}
