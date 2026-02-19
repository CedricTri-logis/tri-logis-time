import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Provides a persistent unique device identifier.
///
/// Uses flutter_secure_storage (iOS Keychain / Android EncryptedSharedPreferences)
/// so the ID persists across app reinstalls on most devices.
class DeviceIdService {
  static const _key = 'persistent_device_id';
  static const _storage = FlutterSecureStorage();
  static String? _cachedId;

  /// Get the persistent device ID, creating one if it doesn't exist.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    var id = await _storage.read(key: _key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: _key, value: id);
    }

    _cachedId = id;
    return id;
  }
}
