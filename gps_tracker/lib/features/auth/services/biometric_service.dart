import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Service for biometric authentication (Face ID / Fingerprint).
///
/// Saves credentials in secure storage after a successful login,
/// then allows re-authentication via biometrics on subsequent launches.
class BiometricService {
  static const _keyEmail = 'bio_email';
  static const _keyPassword = 'bio_password';
  static const _keyEnabled = 'bio_enabled';

  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

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
    final value = await _storage.read(key: _keyEnabled);
    return value == 'true';
  }

  /// Whether we have saved credentials ready for biometric login.
  Future<bool> hasCredentials() async {
    final enabled = await isEnabled();
    if (!enabled) return false;
    final email = await _storage.read(key: _keyEmail);
    final password = await _storage.read(key: _keyPassword);
    return email != null && password != null;
  }

  /// Save credentials after a successful login and enable biometric.
  Future<void> saveCredentials({
    required String email,
    required String password,
  }) async {
    await _storage.write(key: _keyEmail, value: email);
    await _storage.write(key: _keyPassword, value: password);
    await _storage.write(key: _keyEnabled, value: 'true');
  }

  /// Authenticate with biometrics and return saved credentials.
  /// Returns null if authentication fails or is cancelled.
  Future<({String email, String password})?> authenticate() async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Connectez-vous avec la biométrie',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (!authenticated) return null;

      final email = await _storage.read(key: _keyEmail);
      final password = await _storage.read(key: _keyPassword);

      if (email == null || password == null) return null;

      return (email: email, password: password);
    } catch (_) {
      return null;
    }
  }

  /// Clear saved credentials (e.g., on sign out or password change).
  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyEmail);
    await _storage.delete(key: _keyPassword);
    await _storage.delete(key: _keyEnabled);
  }
}

/// Global provider for the biometric service.
final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});
