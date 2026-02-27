import 'package:shared_preferences/shared_preferences.dart';

/// Backup auth tokens in plain SharedPreferences (Firebase Auth model).
///
/// Why plain SharedPreferences instead of flutter_secure_storage?
/// - Immune to Android Keystore corruption (BAD_DECRYPT)
/// - SharedPreferences is never cleared by Samsung battery optimization
/// - If device is rooted, no local storage is safe anyway
/// - Firebase Auth uses this exact approach for the same reasons
///
/// This is a BACKUP — primary tokens remain in flutter_secure_storage
/// for biometric authentication. This backup is only read when the
/// primary store is unavailable (after BAD_DECRYPT recovery).
class SessionBackupService {
  static const _keyRefreshToken = 'backup_refresh_token';
  static const _keyPhone = 'backup_phone';
  static const _keyDeviceId = 'backup_device_id';

  static SharedPreferences? _prefs;

  /// Initialize SharedPreferences. Safe to call multiple times.
  static Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Ensure prefs is ready (lazy init if needed).
  static Future<SharedPreferences> _getPrefs() async {
    if (_prefs == null) await initialize();
    return _prefs!;
  }

  /// Save refresh token backup.
  static Future<void> saveRefreshToken(String token) async {
    final prefs = await _getPrefs();
    await prefs.setString(_keyRefreshToken, token);
  }

  /// Read backed-up refresh token.
  static Future<String?> getRefreshToken() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyRefreshToken);
  }

  /// Save phone number backup (for OTP fallback).
  static Future<void> savePhone(String phone) async {
    final prefs = await _getPrefs();
    await prefs.setString(_keyPhone, phone);
  }

  /// Read backed-up phone number.
  static Future<String?> getPhone() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyPhone);
  }

  /// Save device ID backup (to detect BAD_DECRYPT device ID change).
  static Future<void> saveDeviceId(String deviceId) async {
    final prefs = await _getPrefs();
    await prefs.setString(_keyDeviceId, deviceId);
  }

  /// Read backed-up device ID.
  static Future<String?> getDeviceId() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyDeviceId);
  }

  /// Clear all backups (on explicit user sign-out).
  static Future<void> clear() async {
    final prefs = await _getPrefs();
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyPhone);
    // Keep device ID — it persists across logins
  }
}
