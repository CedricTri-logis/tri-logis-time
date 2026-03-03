# Firebase Silent Push Integration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Firebase Cloud Messaging to the Flutter app so the server can send silent push notifications to wake killed apps, completing the background tracking resilience pipeline.

**Architecture:** The server-side is already deployed (migrations 127-128, Edge Function `send-wake-push`, pg_cron every 2 min). This plan adds the client-side: Firebase project setup, Flutter `firebase_messaging` integration, FCM token registration in `employee_profiles.fcm_token`, and a background message handler that restarts the tracking service.

**Tech Stack:** Firebase Console, `firebase_core` ^3.x, `firebase_messaging` ^15.x, FlutterFire CLI, Kotlin (Android), Swift (iOS)

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

### Task 4: Initialize Firebase and register FCM token

**Files:**
- Create: `gps_tracker/lib/shared/services/fcm_service.dart`
- Modify: `gps_tracker/lib/main.dart:86-94` (add Firebase init)
- Modify: `gps_tracker/lib/app.dart:361-368` (register FCM token after auth)

**Step 1: Create FCM service**

Create `gps_tracker/lib/shared/services/fcm_service.dart`:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/diagnostic_event.dart';
import '../services/diagnostic_logger.dart';

/// Handles FCM token lifecycle and silent push reception.
class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  String? _lastRegisteredToken;

  /// Register the current FCM token to employee_profiles.
  /// Call after successful authentication.
  Future<void> registerToken() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

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

  /// Listen for token refreshes and re-register.
  void listenForTokenRefresh() {
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
    } catch (e) {
      debugPrint('[FCM] Failed to clear token: $e');
    }
  }
}
```

**Step 2: Add Firebase initialization to main.dart**

In `gps_tracker/lib/main.dart`, add the import at the top:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
```

Then, after Supabase initialization (after line 83) and before the services init block (line 86), add:

```dart
  if (initError == null) {
    try {
      await Firebase.initializeApp();
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
                // Register FCM token for silent push wake
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
git commit -m "feat: initialize Firebase and register FCM token on login"
```

---

### Task 5: Add background message handler for silent push wake

**Files:**
- Modify: `gps_tracker/lib/main.dart` (add top-level handler)
- Modify: `gps_tracker/lib/shared/services/fcm_service.dart` (request permissions)

**Step 1: Add top-level background message handler**

In `gps_tracker/lib/main.dart`, add a top-level function **before** `main()`:

```dart
/// Top-level handler for FCM background/terminated messages.
/// Firebase requires this to be a top-level function (not a class method).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Silent push received — the act of launching this handler is the "wake".
  // The app's existing tracking recovery mechanisms (TrackingRescueReceiver
  // on Android, SLC on iOS) will handle restarting GPS tracking.
  // No additional work needed here.
  debugPrint('[FCM] Background message received: ${message.data}');
}
```

Then, inside `main()`, right after `Firebase.initializeApp()`:

```dart
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
```

**Step 2: Request notification permissions (iOS)**

In `gps_tracker/lib/shared/services/fcm_service.dart`, add a method:

```dart
  /// Request push notification permissions.
  /// On Android 13+, POST_NOTIFICATIONS is already in manifest.
  /// On iOS, this requests the APNs permission.
  Future<void> requestPermission() async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: false,     // We don't need visible notifications
        badge: false,
        sound: false,
        provisional: true, // iOS: provisional = silent delivery without prompt
      );
    } catch (e) {
      debugPrint('[FCM] Permission request failed: $e');
    }
  }
```

Call it from `registerToken()` before getting the token:

```dart
  Future<void> registerToken() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      // Request provisional permission (iOS silent delivery)
      await requestPermission();

      final token = await FirebaseMessaging.instance.getToken();
      // ... rest unchanged
```

**Step 3: Verify compile**

```bash
cd gps_tracker
flutter analyze 2>&1 | tail -10
```

Expected: No errors

**Step 4: Commit**

```bash
git add lib/main.dart lib/shared/services/fcm_service.dart
git commit -m "feat: add FCM background message handler for silent push wake"
```

---

### Task 6: Deploy and verify end-to-end

**Step 1: Bump version**

In `gps_tracker/pubspec.yaml`, bump the build number (e.g., `1.0.0+98`).

**Step 2: Deploy to both stores**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
./deploy.sh
```

**Step 3: Enforce minimum version**

```sql
UPDATE app_config SET value = '1.0.0+98', updated_at = now()
WHERE key = 'minimum_app_version';
```

**Step 4: Verify FCM token registration**

After installing the new build and signing in:

```sql
SELECT id, full_name, fcm_token IS NOT NULL as has_token,
       substring(fcm_token from 1 for 20) as token_prefix
FROM employee_profiles
WHERE fcm_token IS NOT NULL;
```

Expected: Your test user should have a non-null `fcm_token`.

**Step 5: Verify wake push pipeline**

1. Start a shift on a test device
2. Wait 5+ minutes without GPS activity (or force-kill the app)
3. Check the Edge Function logs:

```bash
supabase functions logs send-wake-push --project-ref xdyzdclwvhkfwbkrdsiz
```

Expected: `{"sent":1, "total":1, "errors":[]}` within 2 minutes of heartbeat going stale.

**Step 6: Verify device wakes up**

After the silent push is sent, check if the device resumes GPS tracking:
- Android: Check `adb logcat | grep -i "fcm\|wake\|rescue"`
- iOS: Check device console for FCM background message delivery

**Step 7: Commit and wrap up**

```bash
git add -A
git commit -m "chore: deploy v1.0.0+98 with Firebase silent push integration"
```
