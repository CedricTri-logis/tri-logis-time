import 'package:uuid/uuid.dart';

import '../../../shared/services/secure_storage.dart';
import '../../../shared/services/session_backup_service.dart';

/// Provides a persistent unique device identifier.
///
/// Primary storage: flutter_secure_storage (encrypted).
/// Backup: plain SharedPreferences (survives Keystore corruption).
///
/// On BAD_DECRYPT, the encrypted value is lost but the backup remains,
/// so the device ID stays the same — preventing force-logout cascade.
class DeviceIdService {
  static const _key = 'persistent_device_id';
  static String? _cachedId;

  /// Get the persistent device ID, creating one if it doesn't exist.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    // Try primary (encrypted) storage
    String? id;
    try {
      id = await secureStorage.read(key: _key);
    } catch (_) {
      // Secure storage unreadable (BAD_DECRYPT or other error)
      // Fall through to backup
    }

    if (id == null || id.isEmpty) {
      // Primary failed — try SharedPreferences backup
      try {
        id = await SessionBackupService.getDeviceId();
      } catch (_) {}
    }

    if (id == null || id.isEmpty) {
      // Both failed — generate new ID
      id = const Uuid().v4();
    }

    // Write to both stores (best-effort)
    try {
      await secureStorage.write(key: _key, value: id);
    } catch (_) {}
    try {
      await SessionBackupService.saveDeviceId(id);
    } catch (_) {}

    _cachedId = id;
    return id;
  }
}
