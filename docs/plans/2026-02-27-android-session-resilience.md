# Android Session Resilience — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent involuntary logouts on Samsung/Android by adopting Firebase Auth's dual-storage model — refresh tokens backed up in plain SharedPreferences (immune to Keystore corruption), with automatic session recovery after BAD_DECRYPT events.

**Architecture:** Dual-write auth tokens to both `flutter_secure_storage` (encrypted, for biometric auth) and plain `SharedPreferences` (unencrypted backup, survives Keystore corruption). After BAD_DECRYPT recovery, the app auto-restores the session from the SharedPreferences backup and re-registers the device ID — preventing the force-logout cascade caused by device ID regeneration. Enable `autoRefreshToken: true` so the Supabase SDK silently refreshes expired JWTs on cold start.

**Tech Stack:** Dart/Flutter, `shared_preferences` (already transitive dep via supabase_flutter), `flutter_secure_storage` 9.2.4, `supabase_flutter` 2.12.0

**Root Cause (Fabrice's logout):**
1. Samsung killed the foreground service process (Power Saving ON + Android 16)
2. App restarted → `LocalDatabase.initialize()` → Android Keystore corrupted → BAD_DECRYPT
3. `secureStorage.deleteAll()` wiped `persistent_device_id` (+ biometric tokens)
4. New UUID generated for device ID
5. `DeviceSessionNotifier` polling detected device ID mismatch with server
6. `_handleForceLogout()` → `signOut(revokeSession: true)` → complete logout with server-side token revocation

**Firebase Auth's model we're replicating:**
- Tokens in plain SharedPreferences (not encrypted) — rationale: if device is rooted, no local storage is safe; reliability > theoretical root protection
- Auto-refresh on startup
- Refresh tokens never expire (only explicit revocation)

---

### Task 1: Create `SessionBackupService` — SharedPreferences backup for auth tokens

**Files:**
- Create: `lib/shared/services/session_backup_service.dart`

**Step 1: Write the service**

```dart
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
```

**Step 2: Add `shared_preferences` dependency**

Check if already available (it's a transitive dependency of supabase_flutter, but we need it as direct):

```bash
cd gps_tracker && flutter pub add shared_preferences
```

**Step 3: Commit**

```bash
git add lib/shared/services/session_backup_service.dart pubspec.yaml pubspec.lock
git commit -m "feat: add SessionBackupService for plain SharedPreferences token backup"
```

---

### Task 2: Dual-write tokens — biometric save also backs up to SharedPreferences

**Files:**
- Modify: `lib/app.dart` (auth state listener, lines 225-272)
- Modify: `lib/features/auth/services/biometric_service.dart` (`saveSessionTokens`)
- Modify: `lib/features/auth/services/auth_service.dart` (`signOut`)

**Step 1: Add backup write to the auth state listener in `app.dart`**

In the `ref.listen<AsyncValue<AuthState>>` block (lines 225-272), after `bio.saveSessionTokens(...)`, also write to backup:

```dart
// After line 263 (bio.saveSessionTokens), add:
try {
  await SessionBackupService.saveRefreshToken(state.session!.refreshToken!);
  if (phone != null && phone.isNotEmpty) {
    await SessionBackupService.savePhone(phone);
  }
} catch (_) {
  // Best-effort backup — don't block auth flow
}
```

Import `SessionBackupService` at the top of `app.dart`.

**Step 2: Add backup write to `BiometricService.saveSessionTokens()`**

In `biometric_service.dart`, add backup call after secure storage writes:

```dart
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
```

Import `SessionBackupService` at the top of `biometric_service.dart`.

**Step 3: Clear backup on explicit sign-out**

In `auth_service.dart` `signOut()`, add backup clear:

```dart
Future<void> signOut({bool revokeSession = false}) async {
  try {
    await _client.auth.signOut(
      scope: revokeSession ? SignOutScope.global : SignOutScope.local,
    );
  } catch (e) {
    // Sign out should still clear local session even if network fails
  }
  // Clear backup tokens on sign-out
  try {
    await SessionBackupService.clear();
  } catch (_) {}
}
```

Import `SessionBackupService` at the top of `auth_service.dart`.

**Step 4: Commit**

```bash
git add lib/app.dart lib/features/auth/services/biometric_service.dart lib/features/auth/services/auth_service.dart
git commit -m "feat: dual-write auth tokens to SharedPreferences backup on every refresh"
```

---

### Task 3: Backup device ID in SharedPreferences + restore after BAD_DECRYPT

**Files:**
- Modify: `lib/features/auth/services/device_id_service.dart`

**Step 1: Add backup to `DeviceIdService.getDeviceId()`**

When a device ID is created or read, also back it up to SharedPreferences. When secure storage fails (BAD_DECRYPT wipes it), restore from backup instead of generating a new UUID:

```dart
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
```

**This is the key fix for Fabrice's bug**: After BAD_DECRYPT wipes secure storage, the device ID is restored from SharedPreferences backup instead of generating a new UUID. The device session check passes because the device ID hasn't changed.

**Step 2: Commit**

```bash
git add lib/features/auth/services/device_id_service.dart
git commit -m "fix: preserve device ID across Keystore corruption via SharedPreferences backup"
```

---

### Task 4: Add backup-based session recovery in auth recovery flow

**Files:**
- Modify: `lib/app.dart` (`_attemptAuthRecovery`, lines 130-213)

**Step 1: Add SharedPreferences fallback to auth recovery**

When biometric tokens are unavailable (BAD_DECRYPT wiped them), try the SharedPreferences backup before giving up:

```dart
Future<void> _attemptAuthRecovery({required String trigger}) async {
  if (ref.read(_authRecoveryInProgressProvider)) return;
  ref.read(_authRecoveryInProgressProvider.notifier).state = true;

  final logger = DiagnosticLogger.isInitialized
      ? DiagnosticLogger.instance
      : null;

  try {
    final bio = ref.read(biometricServiceProvider);
    final enabled = await bio.isEnabled();
    final hasCreds = await bio.hasCredentials();

    logger?.auth(
      Severity.warn,
      'Auth recovery attempt',
      metadata: {
        'trigger': trigger,
        'biometric_enabled': enabled,
        'has_bio_credentials': hasCreds,
      },
    );

    // Path 1: Try biometric recovery (primary)
    if (enabled && hasCreds) {
      final tokens = await bio.authenticate();
      if (tokens != null) {
        try {
          final authService = ref.read(authServiceProvider);
          final response = await authService.restoreSession(
            refreshToken: tokens.refreshToken,
          );
          if (response.session != null) {
            final phone = Supabase.instance.client.auth.currentUser?.phone;
            await bio.saveSessionTokens(
              accessToken: response.session!.accessToken,
              refreshToken: response.session!.refreshToken!,
              phone: (phone != null && phone.isNotEmpty) ? phone : null,
            );
            logger?.auth(Severity.info, 'Auth recovery succeeded',
                metadata: {'trigger': trigger, 'method': 'biometric'});
            return;
          }
        } catch (e) {
          logger?.auth(Severity.warn, 'Biometric recovery failed, trying backup',
              metadata: {'trigger': trigger, 'error': e.toString()});
        }
      }
    }

    // Path 2: Try SharedPreferences backup (fallback after BAD_DECRYPT)
    try {
      final backupToken = await SessionBackupService.getRefreshToken();
      if (backupToken != null) {
        logger?.auth(Severity.warn, 'Attempting backup token recovery',
            metadata: {'trigger': trigger});
        final authService = ref.read(authServiceProvider);
        final response = await authService.restoreSession(
            refreshToken: backupToken);
        if (response.session != null) {
          // Re-save to biometric storage (if secure storage is working again)
          final phone = Supabase.instance.client.auth.currentUser?.phone;
          try {
            await bio.saveSessionTokens(
              accessToken: response.session!.accessToken,
              refreshToken: response.session!.refreshToken!,
              phone: (phone != null && phone.isNotEmpty) ? phone : null,
            );
          } catch (_) {}
          logger?.auth(Severity.info, 'Auth recovery succeeded',
              metadata: {'trigger': trigger, 'method': 'backup_token'});
          return;
        }
      }
    } catch (e) {
      logger?.auth(Severity.warn, 'Backup token recovery failed',
          metadata: {'trigger': trigger, 'error': e.toString()});
    }

    // Both paths failed — no recovery possible
  } finally {
    if (mounted) {
      ref.read(_authRecoveryInProgressProvider.notifier).state = false;
    }
  }

  // Recovery failed — attempt a safety clock-out to avoid zombie shifts.
  try {
    final shiftState = ref.read(shiftProvider);
    if (shiftState.activeShift != null) {
      await ref
          .read(shiftProvider.notifier)
          .clockOut(reason: 'auth_signed_out');
    }
  } catch (e) {
    logger?.auth(
      Severity.error,
      'Clock-out during auth recovery failed',
      metadata: {'error': e.toString()},
    );
  }
}
```

**Step 2: Commit**

```bash
git add lib/app.dart
git commit -m "feat: add SharedPreferences backup fallback to auth recovery flow"
```

---

### Task 5: Enable `autoRefreshToken: true`

**Files:**
- Modify: `lib/main.dart` (line 78)

**Step 1: Change autoRefreshToken to true**

```dart
// Before:
authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),

// After:
authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
```

**Why:** With `autoRefreshToken: false`, when the app restarts after a process kill, the Supabase SDK loads the expired JWT but does NOT refresh it. The first API call fails with 401. With `autoRefreshToken: true`, the SDK silently refreshes the expired JWT on startup using the stored refresh token. This is what Firebase does.

**Safety:** The existing `_refreshInFlight` mutex in `AuthService.refreshSession()` still protects against concurrent manual refreshes. The SDK's auto-refresh is independent and handles the cold-start case.

**Step 2: Initialize SessionBackupService in main.dart**

Add `SessionBackupService.initialize()` to the parallel init block so SharedPreferences is ready before any token writes:

```dart
// In main.dart, add to the Future.wait block:
await Future.wait([
  LocalDatabase().initialize(),
  _initializeTracking(),
  ShiftActivityService.instance.initialize(),
  SessionBackupService.initialize(), // NEW
]);
```

Import `SessionBackupService` at the top of `main.dart`.

**Step 3: Commit**

```bash
git add lib/main.dart
git commit -m "feat: enable autoRefreshToken for cold-start JWT refresh + init backup service"
```

---

### Task 6: Improve BAD_DECRYPT diagnostic logging

**Files:**
- Modify: `lib/shared/services/local_database.dart` (lines 46-115)

**Step 1: Add more context to the BAD_DECRYPT log**

The current BAD_DECRYPT log at line 98-106 only fires if `DiagnosticLogger.isInitialized`. After BAD_DECRYPT, the logger might not be ready yet. Add a `debugPrint` as fallback, and add the backup recovery info to the log:

```dart
if (recoveredFromBadDecrypt) {
  // Always print to console (logger may not be ready)
  debugPrint('[LocalDatabase] BAD_DECRYPT recovery: wiped secure storage + DB');

  if (DiagnosticLogger.isInitialized) {
    DiagnosticLogger.instance.lifecycle(
      Severity.critical,
      'Database recovery from BAD_DECRYPT',
      metadata: {
        'reason': 'bad_decrypt',
        'action': 'wipe_and_recreate',
        'device_id_preserved': (await SessionBackupService.getDeviceId()) != null,
        'backup_token_available': (await SessionBackupService.getRefreshToken()) != null,
      },
    );
  }
}
```

Add `import 'package:flutter/foundation.dart';` and `import 'session_backup_service.dart';` to local_database.dart.

**Step 2: Commit**

```bash
git add lib/shared/services/local_database.dart
git commit -m "fix: improve BAD_DECRYPT diagnostic logging with backup recovery status"
```

---

### Task 7: Clear backup on explicit sign-out from sign_in_screen and home_screen

**Files:**
- Modify: `lib/features/auth/screens/sign_in_screen.dart` (clearCredentials paths)
- Modify: `lib/features/home/home_screen.dart` (sign-out handler)

**Step 1: Clear backup when biometric credentials are cleared**

In `sign_in_screen.dart`, wherever `bio.clearCredentials()` is called, also clear the backup:

Search for `clearCredentials()` calls and add `SessionBackupService.clear()` alongside.

**Step 2: Verify home_screen sign-out already calls `authService.signOut()`**

Since we added `SessionBackupService.clear()` to `AuthService.signOut()` in Task 2, home_screen is already covered.

**Step 3: Commit**

```bash
git add lib/features/auth/screens/sign_in_screen.dart
git commit -m "fix: clear SharedPreferences backup when biometric credentials are cleared"
```

---

## Summary of Changes

| File | Change | Purpose |
|------|--------|---------|
| `session_backup_service.dart` | NEW | SharedPreferences backup (Firebase model) |
| `device_id_service.dart` | MODIFIED | Restore device ID from backup after BAD_DECRYPT |
| `biometric_service.dart` | MODIFIED | Dual-write tokens to backup |
| `auth_service.dart` | MODIFIED | Clear backup on sign-out |
| `app.dart` | MODIFIED | Dual-write in auth listener + backup fallback in recovery |
| `main.dart` | MODIFIED | `autoRefreshToken: true` + init backup service |
| `local_database.dart` | MODIFIED | Better BAD_DECRYPT logging |
| `sign_in_screen.dart` | MODIFIED | Clear backup on credential clear |

## What This Fixes

1. **BAD_DECRYPT → force-logout cascade (Fabrice's bug):** Device ID is restored from SharedPreferences backup instead of regenerated → no device mismatch → no force-logout.

2. **Session loss after Keystore corruption:** Refresh token is backed up in plain SharedPreferences → auto-recovery without user interaction.

3. **Cold-start JWT expiry:** `autoRefreshToken: true` → SDK silently refreshes expired JWT on restart.

4. **Phone number loss for OTP fallback:** Phone backed up in SharedPreferences → OTP re-auth works even after BAD_DECRYPT.

## What This Does NOT Fix (Samsung-side, user must configure)

- "Economie d'energie" (Power Saving) must be OFF for reliable background GPS
- App should be added to "Applis jamais mises en veille auto" BEFORE setting to "Non restreinte"
- These are user-facing instructions, not code fixes
