import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../../shared/services/secure_storage.dart';
import '../../../shared/services/session_backup_service.dart';

/// Service for biometric authentication (Face ID / Fingerprint).
///
/// Stores Supabase session tokens (access + refresh) in secure storage
/// after a successful login, then restores the session via biometrics.
class BiometricService {
  // New token-based keys
  static const _keyAccessToken = 'bio_access_token';
  static const _keyRefreshToken = 'bio_refresh_token';
  static const _keyEnabled = 'bio_enabled';
  static const _keyPhone = 'bio_phone';

  // Legacy credential keys (for migration from email+password storage)
  static const _keyLegacyEmail = 'bio_email';
  static const _keyLegacyPassword = 'bio_password';

  final LocalAuthentication _localAuth = LocalAuthentication();

  /// Check if the device supports biometrics and has enrolled biometrics.
  Future<bool> isAvailable() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;

      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether the user has opted in to biometric login.
  Future<bool> isEnabled() async {
    final value = await secureStorage.read(key: _keyEnabled);
    return value == 'true';
  }

  /// Whether we have saved tokens (or legacy credentials) ready for biometric login.
  Future<bool> hasCredentials() async {
    final enabled = await isEnabled();
    if (!enabled) return false;

    // Check new token-based storage first
    final refreshToken = await secureStorage.read(key: _keyRefreshToken);
    if (refreshToken != null) return true;

    // Fall back to legacy credentials
    final email = await secureStorage.read(key: _keyLegacyEmail);
    final password = await secureStorage.read(key: _keyLegacyPassword);
    return email != null && password != null;
  }

  /// Save session tokens after a successful login and enable biometric.
  /// Also cleans up legacy credential keys if they exist.
  Future<void> saveSessionTokens({
    required String accessToken,
    required String refreshToken,
    String? phone,
  }) async {
    // Primary: encrypted storage (for biometric auth)
    await secureStorage.write(key: _keyAccessToken, value: accessToken);
    await secureStorage.write(key: _keyRefreshToken, value: refreshToken);
    await secureStorage.write(key: _keyEnabled, value: 'true');
    if (phone != null) {
      await secureStorage.write(key: _keyPhone, value: phone);
    }

    // Backup: plain SharedPreferences (survives Keystore corruption)
    try {
      await SessionBackupService.saveRefreshToken(refreshToken);
      if (phone != null) {
        await SessionBackupService.savePhone(phone);
      }
    } catch (_) {
      // Best-effort — secure storage is the primary
    }

    // Clean up legacy keys
    await secureStorage.delete(key: _keyLegacyEmail);
    await secureStorage.delete(key: _keyLegacyPassword);
  }

  /// Get the saved phone number for OTP fallback when refresh token expires.
  Future<String?> getSavedPhone() async {
    return secureStorage.read(key: _keyPhone);
  }

  /// Authenticate with biometrics and return saved session tokens.
  /// Returns null if authentication fails or is cancelled.
  Future<({String accessToken, String refreshToken})?> authenticate() async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Connectez-vous avec la biometrie',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (!authenticated) return null;

      final accessToken = await secureStorage.read(key: _keyAccessToken);
      final refreshToken = await secureStorage.read(key: _keyRefreshToken);

      if (accessToken != null && refreshToken != null) {
        return (accessToken: accessToken, refreshToken: refreshToken);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// Get legacy email+password credentials (for transparent migration).
  /// Returns null if no legacy credentials exist.
  Future<({String email, String password})?> getLegacyCredentials() async {
    try {
      final email = await secureStorage.read(key: _keyLegacyEmail);
      final password = await secureStorage.read(key: _keyLegacyPassword);

      if (email != null && password != null) {
        return (email: email, password: password);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Prompt biometric authentication only (no credential retrieval).
  /// Used for legacy migration flow where we need bio auth first,
  /// then handle credentials separately.
  Future<bool> authenticateOnly() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Connectez-vous avec la biometrie',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Clear all saved credentials and tokens (both legacy, new, and backup).
  Future<void> clearCredentials() async {
    await secureStorage.delete(key: _keyAccessToken);
    await secureStorage.delete(key: _keyRefreshToken);
    await secureStorage.delete(key: _keyEnabled);
    await secureStorage.delete(key: _keyPhone);
    await secureStorage.delete(key: _keyLegacyEmail);
    await secureStorage.delete(key: _keyLegacyPassword);
    // Also clear SharedPreferences backup to prevent stale token recovery
    try {
      await SessionBackupService.clear();
    } catch (_) {}
  }
}

/// Global provider for the biometric service.
final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});
