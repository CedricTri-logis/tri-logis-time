# Firebase Silent Push Integration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Firebase Cloud Messaging to the Flutter app so the server can send silent push notifications to wake killed apps, completing the background tracking resilience pipeline.

**Architecture:** The server-side is already deployed (migrations 127-128, Edge Function `send-wake-push`, pg_cron every 2 min). This plan adds the client-side: Firebase project setup, Flutter `firebase_messaging` integration, FCM token registration in `employee_profiles.fcm_token`, and a background message handler that restarts the tracking service.

**Tech Stack:** Firebase Console, `firebase_core` ^3.x, `firebase_messaging` ^15.x, FlutterFire CLI, Kotlin (Android), Swift (iOS)

## Safety Design Principles

1. **Remote kill switch**: An `fcm_enabled` flag in `app_config` controls all FCM behavior. Flip server-side to disable without redeploying.
2. **Non-blocking init**: Firebase initializes *after* tracking recovery, not in the critical startup path. Tracking always starts first.
3. **Additive only**: FCM is a new recovery layer. It does not replace or modify existing mechanisms (SLC, rescue alarms, WorkManager, app resume recovery).
4. **Easy removal**: All FCM code is isolated in `fcm_service.dart` + 3 call sites (main.dart, app.dart). Revert those + gradle/config files to fully remove.
5. **Gradual rollout**: Start with test employees only before enabling globally.

---

### Task 0: Add remote kill switch migration

**Files:**
- Create: `supabase/migrations/XXX_fcm_enabled_flag.sql`

**Step 1: Create migration**

```sql
-- Add FCM kill switch to app_config
-- Set to 'false' initially — enable per-employee after verification
INSERT INTO app_config (key, value)
VALUES ('fcm_enabled', 'false')
ON CONFLICT (key) DO NOTHING;

-- Optional: per-employee override for gradual rollout
-- When fcm_enabled = 'false' globally, only employees listed here get FCM
-- When fcm_enabled = 'true' globally, all employees get FCM
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS fcm_opt_in BOOLEAN NOT NULL DEFAULT false;
```

**Step 2: Apply migration**

```bash
supabase db push --project-ref xdyzdclwvhkfwbkrdsiz
```

**Step 3: Enable for test employees**

```sql
UPDATE employee_profiles SET fcm_opt_in = true
WHERE email IN ('cedric@trilogis.ca');  -- start with yourself
```

**Step 4: Commit**

```bash
git add supabase/migrations/
git commit -m "feat: add FCM kill switch (app_config + per-employee opt-in)"
```

---

### Task 1: Create Firebase project and configure apps (MANUAL)

> This task requires manual steps in the Firebase Console. It cannot be automated.

**Step 1: Create Firebase project**

1. Go to https://console.firebase.google.com
2. Click "Add project"
3. Name: `tri-logis-time` (or similar)
4. Disable Google Analytics (not needed for FCM)
5. Click "Create project"

**Step 2: Add Android app**

1. In Firebase Console → Project settings → Add app → Android
2. Package name: `ca.trilogis.gpstracker`
3. App nickname: `Tri-Logis Time Android`
4. Skip SHA-1 for now (not needed for FCM)
5. Download `google-services.json`
6. Place it at: `gps_tracker/android/app/google-services.json`

**Step 3: Add iOS app**

1. In Firebase Console → Project settings → Add app → iOS
2. Bundle ID: `ca.trilogis.gpstracker`
3. App nickname: `Tri-Logis Time iOS`
4. Download `GoogleService-Info.plist`
5. Place it at: `gps_tracker/ios/Runner/GoogleService-Info.plist`

**Step 4: Configure APNs for iOS push**

1. In Apple Developer → Certificates, IDs & Profiles → Keys
2. Create a new APNs key (or reuse existing)
3. Download the `.p8` file
4. In Firebase Console → Project settings → Cloud Messaging → iOS
5. Upload the APNs auth key (.p8), enter Key ID and Team ID

**Step 5: Get Firebase service account key for server-side**

1. In Firebase Console → Project settings → Service accounts
2. Click "Generate new private key"
3. Download the JSON file
4. Set it as a Supabase secret:

```bash
# Minify the JSON to a single line first:
cat firebase-service-account.json | jq -c '.' > /tmp/fb-key.json

# Set as Supabase secret:
supabase secrets set FIREBASE_SERVICE_ACCOUNT_KEY="$(cat /tmp/fb-key.json)" --project-ref xdyzdclwvhkfwbkrdsiz

# Clean up:
rm /tmp/fb-key.json
```

**Step 6: Verify server-side integration**

```bash
# Test the Edge Function manually:
curl -X POST https://xdyzdclwvhkfwbkrdsiz.supabase.co/functions/v1/send-wake-push \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

Expected: `{"sent":0}` (no stale devices yet, but no more `skipped: true`)

**Step 7: Commit config files**

```bash
cd gps_tracker
git add android/app/google-services.json
git add ios/Runner/GoogleService-Info.plist
git commit -m "chore: add Firebase config files for FCM silent push"
```

> **IMPORTANT:** `google-services.json` and `GoogleService-Info.plist` are safe to commit — they contain only public project identifiers, not secrets.

---

### Task 2: Add Firebase dependencies and Android Gradle config

**Files:**
- Modify: `gps_tracker/pubspec.yaml` (dependencies section)
- Modify: `gps_tracker/android/settings.gradle.kts` (add google-services plugin)
- Modify: `gps_tracker/android/app/build.gradle.kts` (apply google-services plugin)

**Step 1: Add Flutter dependencies**

In `gps_tracker/pubspec.yaml`, add to the `dependencies:` section (after existing deps):

```yaml
  firebase_core: ^3.12.1
  firebase_messaging: ^15.2.4
```

**Step 2: Add Google Services plugin to Android settings.gradle.kts**

In `gps_tracker/android/settings.gradle.kts`, add the google-services plugin to the `plugins` block:

```kotlin
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false  // <-- ADD
}
```

**Step 3: Apply Google Services plugin in app/build.gradle.kts**

In `gps_tracker/android/app/build.gradle.kts`, add the plugin to the `plugins` block:

```kotlin
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")  // <-- ADD
}
```

**Step 4: Run pub get and verify build**

```bash
cd gps_tracker
flutter pub get
flutter build apk --debug 2>&1 | tail -5
```

Expected: BUILD SUCCESSFUL

**Step 5: Verify iOS builds**

```bash
cd gps_tracker/ios
pod install
cd ..
flutter build ios --debug --no-codesign 2>&1 | tail -5
```

Expected: BUILD SUCCESSFUL

**Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock android/settings.gradle.kts android/app/build.gradle.kts ios/Podfile.lock
git commit -m "feat: add firebase_core and firebase_messaging dependencies"
```

---

### Task 3: Add GoogleService-Info.plist to Xcode project

**Files:**
- Modify: `gps_tracker/ios/Runner.xcodeproj/project.pbxproj`

> The `GoogleService-Info.plist` file must be registered in the Xcode project to be included in the app bundle. Without this, Firebase init will crash at runtime with "Could not locate configuration file: 'GoogleService-Info.plist'."

**Step 1: Add to Xcode project via command line**

The simplest way is to open Xcode and drag the file into the Runner group, but since we're scripting:

```bash
cd gps_tracker/ios
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Runner.xcodeproj')
group = project.main_group.find_subpath('Runner', true)
ref = group.new_file('Runner/GoogleService-Info.plist')
target = project.targets.first
target.resources_build_phase.add_file_reference(ref)
project.save
" 2>/dev/null || echo "NOTE: If xcodeproj gem not available, add file manually in Xcode"
```

**Alternative (manual):** Open `gps_tracker/ios/Runner.xcodeproj` in Xcode, right-click Runner folder → Add Files → select `GoogleService-Info.plist` → ensure "Copy items if needed" is unchecked and Runner target is checked.

**Step 2: Verify the file is bundled**

```bash
cd gps_tracker
flutter build ios --debug --no-codesign 2>&1 | tail -5
```

Expected: BUILD SUCCESSFUL (no "Could not locate configuration file" errors)

**Step 3: Commit**

```bash
git add ios/Runner.xcodeproj/project.pbxproj
git commit -m "chore: add GoogleService-Info.plist to Xcode project"
```

---

### Task 4: Initialize Firebase (non-blocking) and create FCM service

**Files:**
- Create: `gps_tracker/lib/shared/services/fcm_service.dart`
- Modify: `gps_tracker/lib/main.dart` (add Firebase init AFTER tracking recovery)
- Modify: `gps_tracker/lib/app.dart` (register FCM token after auth)

> **IMPORTANT**: Firebase init must NOT block the critical startup path. Tracking recovery must complete first. Firebase is fire-and-forget.

**Step 1: Create FCM service**

Create `gps_tracker/lib/shared/services/fcm_service.dart`:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/diagnostic_event.dart';
import '../services/diagnostic_logger.dart';

/// Handles FCM token lifecycle and silent push reception.
///
/// All methods are no-op safe: they catch errors internally and never throw.
/// Removing this file + its 3 call sites fully disables FCM.
class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  String? _lastRegisteredToken;
  bool _permissionRequested = false;
  bool _tokenRefreshListening = false;

  /// Check if FCM is enabled for this employee via app_config + per-employee opt-in.
  /// Returns false if anything fails (safe default = disabled).
  Future<bool> _isEnabled() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return false;

      // Check global kill switch
      final configResult = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('key', 'fcm_enabled')
          .maybeSingle();

      final globalEnabled = configResult?['value'] == 'true';

      if (globalEnabled) return true;

      // Global is off — check per-employee opt-in for gradual rollout
      final profileResult = await Supabase.instance.client
          .from('employee_profiles')
          .select('fcm_opt_in')
          .eq('id', user.id)
          .maybeSingle();

      return profileResult?['fcm_opt_in'] == true;
    } catch (e) {
      debugPrint('[FCM] Kill switch check failed (defaulting to disabled): $e');
      return false;
    }
  }

  /// Register the current FCM token to employee_profiles.
  /// Call after successful authentication. No-op if FCM disabled.
  Future<void> registerToken() async {
    try {
      if (!await _isEnabled()) return;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      // Request permission once per session (cached)
      if (!_permissionRequested) {
        await _requestPermission();
        _permissionRequested = true;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      // Skip if same token was already registered this session
      if (token == _lastRegisteredToken) return;

      await Supabase.instance.client
          .from('employee_profiles')
          .update({'fcm_token': token})
          .eq('id', user.id);

      _lastRegisteredToken = token;

      _logger?.lifecycle(
        Severity.info,
        'FCM token registered',
        metadata: {'token_prefix': token.substring(0, 12)},
      );
    } catch (e) {
      _logger?.error(
        Severity.warn,
        'FCM token registration failed',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Listen for token refreshes and re-register. Safe to call multiple times.
  void listenForTokenRefresh() {
    if (_tokenRefreshListening) return;
    _tokenRefreshListening = true;

    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      _lastRegisteredToken = null; // Force re-registration
      await registerToken();
    });
  }

  /// Clear FCM token from server on sign-out.
  Future<void> clearToken() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      await Supabase.instance.client
          .from('employee_profiles')
          .update({'fcm_token': null})
          .eq('id', user.id);

      _lastRegisteredToken = null;
      _permissionRequested = false;
    } catch (e) {
      debugPrint('[FCM] Failed to clear token: $e');
    }
  }

  /// Request push notification permissions.
  /// On Android 13+, POST_NOTIFICATIONS is already in manifest.
  /// On iOS, provisional = silent delivery without user prompt.
  Future<void> _requestPermission() async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: false,
        badge: false,
        sound: false,
        provisional: true,
      );
    } catch (e) {
      debugPrint('[FCM] Permission request failed: $e');
    }
  }
}
```

**Step 2: Add Firebase initialization to main.dart (NON-BLOCKING, after tracking)**

In `gps_tracker/lib/main.dart`, add the imports at the top:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
```

Add the top-level background handler **before** `main()`:

```dart
/// Top-level handler for FCM background/terminated messages.
/// Firebase requires this to be a top-level function (not a class method).
///
/// On iOS: receiving this silent push relaunches the full app (main() re-runs),
/// so the existing tracking recovery handles restart.
/// On Android: the rescue alarm chain handles restart independently.
///
/// We write a breadcrumb for debugging + to satisfy Apple's "useful work"
/// requirement for silent push budget.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = DateTime.now().toIso8601String();
    final breadcrumbs = prefs.getStringList('fcm_wake_breadcrumbs') ?? [];
    breadcrumbs.add('$timestamp|fcm_wake|${message.data['type'] ?? 'unknown'}');
    // Keep last 20 breadcrumbs only
    if (breadcrumbs.length > 20) {
      breadcrumbs.removeRange(0, breadcrumbs.length - 20);
    }
    await prefs.setStringList('fcm_wake_breadcrumbs', breadcrumbs);
  } catch (_) {
    // Silently fail — this is a best-effort breadcrumb
  }
}
```

Then, **after** tracking initialization completes (after `_initializeTracking()` and all critical services), add Firebase init as fire-and-forget:

```dart
  // Firebase init — non-blocking, after tracking recovery completes.
  // FCM is an additive recovery layer; tracking must not wait for it.
  if (initError == null) {
    unawaited(_initializeFirebase());
  }
```

Add the helper function:

```dart
Future<void> _initializeFirebase() async {
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    debugPrint('[Main] Firebase initialized successfully');
  } catch (e) {
    // Non-fatal: app works without Firebase, just no silent push wake
    debugPrint('[Main] Firebase init failed (non-critical): $e');
  }
}
```

**Step 3: Register FCM token after authentication in app.dart**

In `gps_tracker/lib/app.dart`, add the import:

```dart
import '../shared/services/fcm_service.dart';
```

Inside the `build` method, in the block where `state.session != null` and `!isLocked` (around lines 361-368), after `DeviceInfoService` sync, add:

```dart
                // Register FCM token for silent push wake (no-op if disabled)
                FcmService().registerToken();
                FcmService().listenForTokenRefresh();
```

**Step 4: Clear token on sign-out**

In `gps_tracker/lib/app.dart`, in the `ref.listen<AsyncValue<AuthState>>` callback, inside the `state.event == AuthChangeEvent.signedOut` block (around line 293), add before the recovery attempt:

```dart
          // Clear FCM token on sign-out
          FcmService().clearToken();
```

**Step 5: Verify the app compiles**

```bash
cd gps_tracker
flutter analyze 2>&1 | tail -10
```

Expected: No errors (warnings OK)

**Step 6: Commit**

```bash
git add lib/shared/services/fcm_service.dart lib/main.dart lib/app.dart
git commit -m "feat: initialize Firebase (non-blocking) and register FCM token with kill switch"
```

---

### Task 5: Deploy and verify end-to-end

**Step 1: Bump version**

In `gps_tracker/pubspec.yaml`, bump the build number.

**Step 2: Deploy to both stores**

```bash
./deploy.sh
```

**Step 3: Enable FCM for test employee only**

```sql
-- Do NOT enable globally yet
UPDATE employee_profiles SET fcm_opt_in = true
WHERE email = 'cedric@trilogis.ca';
```

**Step 4: Verify FCM token registration**

After installing the new build and signing in:

```sql
SELECT id, full_name, fcm_token IS NOT NULL as has_token,
       substring(fcm_token from 1 for 20) as token_prefix,
       fcm_opt_in
FROM employee_profiles
WHERE fcm_opt_in = true;
```

Expected: Test user should have a non-null `fcm_token`.

**Step 5: Verify wake push pipeline**

1. Start a shift on the test device
2. Wait 5+ minutes without GPS activity (or force-kill the app)
3. Check the Edge Function logs:

```bash
supabase functions logs send-wake-push --project-ref xdyzdclwvhkfwbkrdsiz
```

Expected: `{"sent":1, "total":1, "errors":[]}` within 2 minutes of heartbeat going stale.

**Step 6: Verify breadcrumb was written**

After receiving a wake push, check SharedPreferences for the breadcrumb:

```dart
// In debug console or via diagnostic log:
final prefs = await SharedPreferences.getInstance();
final breadcrumbs = prefs.getStringList('fcm_wake_breadcrumbs');
print(breadcrumbs); // Should show timestamp|fcm_wake|wake
```

**Step 7: Verify device wakes up**

After the silent push is sent, check if the device resumes GPS tracking:
- Android: Check `adb logcat | grep -i "fcm\|wake\|rescue"`
- iOS: Check device console for FCM background message delivery

**Step 8: If all good — enable globally**

```sql
UPDATE app_config SET value = 'true', updated_at = now()
WHERE key = 'fcm_enabled';
```

**Step 9: If bugs found — disable instantly (no deploy needed)**

```sql
-- Disable globally
UPDATE app_config SET value = 'false', updated_at = now()
WHERE key = 'fcm_enabled';

-- Or disable for a specific employee
UPDATE employee_profiles SET fcm_opt_in = false
WHERE email = 'problematic-employee@trilogis.ca';
```

**Step 10: Commit and wrap up**

```bash
git add -A
git commit -m "chore: deploy with Firebase silent push integration (gradual rollout)"
```

---

## Rollback Guide

If FCM needs to be fully removed from the codebase:

1. **Instant disable (no deploy):** `UPDATE app_config SET value = 'false' WHERE key = 'fcm_enabled';`
2. **Full removal (requires deploy):**
   - Delete `gps_tracker/lib/shared/services/fcm_service.dart`
   - Revert `main.dart`: remove `_initializeFirebase()`, `_firebaseMessagingBackgroundHandler`, Firebase imports
   - Revert `app.dart`: remove `FcmService()` calls and import
   - Revert `pubspec.yaml`: remove `firebase_core`, `firebase_messaging`
   - Revert `android/settings.gradle.kts`: remove google-services plugin line
   - Revert `android/app/build.gradle.kts`: remove google-services plugin line
   - Delete `android/app/google-services.json`
   - Delete `ios/Runner/GoogleService-Info.plist` + revert `project.pbxproj`
   - Run `flutter pub get` + `cd ios && pod install`
