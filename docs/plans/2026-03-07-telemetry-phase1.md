# Telemetry Expansion Phase 1 — Crashlytics + Battery + Lifecycle

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Capture all Dart/native crashes via Firebase Crashlytics, add battery level to every GPS point, log full app lifecycle, and expand diagnostic_logs categories — all Dart-only, zero native code.

**Architecture:** Crashlytics wired into existing Firebase setup via `runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError`. Battery level read via `battery_plus` in the GPS tracking handler. All events double-written to both Crashlytics and DiagnosticLogger. New diagnostic categories added via Supabase migration.

**Tech Stack:** firebase_crashlytics ^4.3.0, battery_plus ^6.2.0, existing firebase_core/DiagnosticLogger/Supabase

**Design doc:** `docs/plans/2026-03-07-telemetry-expansion-design.md`

---

### Task 1: Supabase migration — battery_level + expanded categories

**Files:**
- Create: `supabase/migrations/109_telemetry_phase1.sql`

**Step 1: Write the migration**

```sql
-- Migration 109: Telemetry Phase 1
-- Adds battery_level to gps_points and expands diagnostic_logs categories.

-- 1. Battery level on GPS points
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS battery_level SMALLINT;
COMMENT ON COLUMN gps_points.battery_level IS 'Battery percentage (0-100) at time of GPS capture';

-- 2. Expand diagnostic_logs event categories
ALTER TABLE diagnostic_logs
  DROP CONSTRAINT IF EXISTS diagnostic_logs_event_category_check;

ALTER TABLE diagnostic_logs
  ADD CONSTRAINT diagnostic_logs_event_category_check
    CHECK (event_category IN (
      'gps', 'shift', 'sync', 'auth', 'permission',
      'lifecycle', 'thermal', 'error', 'network',
      'battery', 'memory', 'crash', 'service',
      'satellite', 'doze', 'motion', 'metrickit'
    ));

-- 3. Update sync_gps_points to accept battery_level
CREATE OR REPLACE FUNCTION sync_gps_points(p_points JSONB)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_point JSONB;
    v_inserted INTEGER := 0;
    v_duplicates INTEGER := 0;
    v_errors INTEGER := 0;
    v_failed_ids JSONB := '[]'::JSONB;
    v_client_id TEXT;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    FOR v_point IN SELECT * FROM jsonb_array_elements(p_points)
    LOOP
        v_client_id := v_point->>'client_id';
        BEGIN
            INSERT INTO gps_points (
                client_id, shift_id, employee_id,
                latitude, longitude, accuracy,
                captured_at, device_id,
                speed, speed_accuracy,
                heading, heading_accuracy,
                altitude, altitude_accuracy,
                is_mocked, battery_level
            )
            VALUES (
                (v_client_id)::UUID,
                (v_point->>'shift_id')::UUID,
                v_user_id,
                (v_point->>'latitude')::DECIMAL,
                (v_point->>'longitude')::DECIMAL,
                (v_point->>'accuracy')::DECIMAL,
                (v_point->>'captured_at')::TIMESTAMPTZ,
                v_point->>'device_id',
                (v_point->>'speed')::DECIMAL,
                (v_point->>'speed_accuracy')::DECIMAL,
                (v_point->>'heading')::DECIMAL,
                (v_point->>'heading_accuracy')::DECIMAL,
                (v_point->>'altitude')::DECIMAL,
                (v_point->>'altitude_accuracy')::DECIMAL,
                (v_point->>'is_mocked')::BOOLEAN,
                (v_point->>'battery_level')::SMALLINT
            );
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation THEN
            v_duplicates := v_duplicates + 1;
        WHEN OTHERS THEN
            v_errors := v_errors + 1;
            v_failed_ids := v_failed_ids || to_jsonb(v_client_id);
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'status', 'success',
        'inserted', v_inserted,
        'duplicates', v_duplicates,
        'errors', v_errors,
        'failed_ids', v_failed_ids
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration**

Run via Supabase MCP `apply_migration` or:
```bash
cd supabase && supabase db push
```

**Step 3: Commit**

```bash
git add supabase/migrations/109_telemetry_phase1.sql
git commit -m "feat: migration 109 — battery_level on gps_points + expanded diagnostic categories"
```

---

### Task 2: Add firebase_crashlytics and battery_plus packages

**Files:**
- Modify: `gps_tracker/pubspec.yaml`

**Step 1: Add dependencies**

Add after line 46 (`firebase_messaging: ^15.2.4`):

```yaml
  firebase_crashlytics: ^4.3.0
  battery_plus: ^6.2.0
```

**Step 2: Install**

```bash
cd gps_tracker && flutter pub get
```

**Step 3: Verify no conflicts**

```bash
cd gps_tracker && flutter analyze
```
Expected: No new errors

**Step 4: Commit**

```bash
cd gps_tracker
git add pubspec.yaml pubspec.lock
git commit -m "chore: add firebase_crashlytics and battery_plus packages"
```

---

### Task 3: Add new categories to Dart EventCategory enum

**Files:**
- Modify: `gps_tracker/lib/shared/models/diagnostic_event.dart`

**Step 1: Add new enum values**

Replace the `EventCategory` enum (lines 6-16) with:

```dart
enum EventCategory {
  gps,
  shift,
  sync,
  auth,
  permission,
  lifecycle,
  thermal,
  error,
  network,
  // Phase 1 additions
  battery,
  crash,
  // Phase 2/3 placeholders (match server constraint)
  memory,
  service,
  satellite,
  doze,
  motion,
  metrickit;

  String get value => name;
}
```

**Step 2: Add convenience methods to DiagnosticLogger**

In `gps_tracker/lib/shared/services/diagnostic_logger.dart`, add after the `permission` method (line 175):

```dart
  Future<void> battery(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.battery, severity: severity, message: message, shiftId: shiftId, metadata: metadata);

  Future<void> crash(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.crash, severity: severity, message: message, metadata: metadata);

  Future<void> memory(Severity severity, String message, {
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.memory, severity: severity, message: message, metadata: metadata);

  Future<void> service(Severity severity, String message, {
    String? shiftId,
    Map<String, dynamic>? metadata,
  }) => log(category: EventCategory.service, severity: severity, message: message, shiftId: shiftId, metadata: metadata);
```

**Step 3: Verify**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors

**Step 4: Commit**

```bash
cd gps_tracker
git add lib/shared/models/diagnostic_event.dart lib/shared/services/diagnostic_logger.dart
git commit -m "feat: add battery, crash, memory, service diagnostic categories"
```

---

### Task 4: Wire Crashlytics + unhandled exception handlers in main.dart

**Files:**
- Modify: `gps_tracker/lib/main.dart`

**Step 1: Add imports**

Add after line 9 (`import 'package:firebase_messaging/firebase_messaging.dart';`):

```dart
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
```

**Step 2: Wrap runApp in runZonedGuarded**

Replace lines 201-206 (the final `runApp` block) with:

```dart
  runApp(
    const ProviderScope(
      child: GpsTrackerApp(),
    ),
  );
```

This stays the same — we add the Crashlytics wiring in `_initializeFirebase()` instead, because Firebase init is deferred (3-second delay for background launch safety). Crashlytics handlers MUST be set after `Firebase.initializeApp()`.

**Step 3: Wire Crashlytics in _initializeFirebase**

Replace the `_initializeFirebase` function (lines 308-322) with:

```dart
Future<void> _initializeFirebase() async {
  if (_firebaseInitialized) return;
  _firebaseInitialized = true;
  try {
    await Firebase.initializeApp();

    // --- Crashlytics setup ---
    // Pass all uncaught Flutter framework errors to Crashlytics
    FlutterError.onError = (details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      // Double-write to DiagnosticLogger for Supabase visibility
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.crash(
          Severity.critical,
          'Flutter error: ${details.exceptionAsString()}',
          metadata: {
            'stack': details.stack?.toString().take(500),
            'library': details.library,
          },
        );
      }
    };

    // Pass uncaught async errors to Crashlytics
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.crash(
          Severity.critical,
          'Platform error: $error',
          metadata: {'stack': stack.toString().take(500)},
        );
      }
      return true;
    };

    // Set user identifier for Crashlytics (if logged in)
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      FirebaseCrashlytics.instance.setUserIdentifier(userId);
    }

    // Update Crashlytics user on auth changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final uid = data.session?.user.id;
      FirebaseCrashlytics.instance.setUserIdentifier(uid ?? '');
    });

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    FcmService().initialize();
    debugPrint('[Main] Firebase + Crashlytics initialized successfully');
  } catch (e) {
    _firebaseInitialized = false;
    debugPrint('[Main] Firebase init failed (non-critical): $e');
  }
}
```

Note: `String.take(500)` doesn't exist in Dart. Use a helper or substring:

```dart
// Add this extension at the bottom of main.dart (or in a shared utils file):
extension _SafeSubstring on String? {
  String? take(int n) => this == null ? null : (this!.length <= n ? this : this!.substring(0, n));
}
```

**Step 4: Add the import for dart:ui (PlatformDispatcher)**

Add at the top of main.dart if not already present:

```dart
import 'dart:ui';
```

Note: `PlatformDispatcher` is from `dart:ui`, which may already be available transitively. Check if the import is needed.

**Step 5: Verify**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors

**Step 6: Commit**

```bash
cd gps_tracker
git add lib/main.dart
git commit -m "feat: wire Crashlytics + unhandled exception handlers with DiagnosticLogger double-write"
```

---

### Task 5: Add battery level capture to GPS tracking handler

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`

**Important constraint:** The GPS handler runs in a **background isolate**. The `battery_plus` package may not work in a background isolate because it uses platform channels. Instead, we read battery level in the **main isolate** and pass it to the background handler via `FlutterForegroundTask.sendDataToMain`.

**Alternative approach (simpler):** Read battery in the main isolate's sync service when preparing GPS points for upload. This avoids any background isolate complexity.

**Step 1: Create a battery service**

Create `gps_tracker/lib/shared/services/battery_service.dart`:

```dart
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Simple battery level reader. Fire-and-forget, never crashes.
class BatteryService {
  static final Battery _battery = Battery();
  static int? _lastLevel;

  /// Get current battery level (0-100). Returns null on failure.
  static Future<int?> getLevel() async {
    try {
      _lastLevel = await _battery.batteryLevel;
      return _lastLevel;
    } catch (_) {
      return _lastLevel; // Return last known value on failure
    }
  }

  /// Get last known battery level without async call.
  static int? get lastKnownLevel => _lastLevel;
}
```

**Step 2: Include battery_level in GPS point data sent from handler**

The GPS handler sends point data to the main isolate via `FlutterForegroundTask.sendDataToMain`. The main isolate's `BackgroundTrackingService` receives it and stores it in the local database.

In `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`, find where GPS point data is received from the background handler and stored locally. Add a battery level read there before inserting into local DB.

Find the method that processes incoming GPS point messages (look for `type: 'gps_point'` or similar). Before the local insert, add:

```dart
final batteryLevel = await BatteryService.getLevel();
// Add to point data:
pointData['battery_level'] = batteryLevel;
```

**Step 3: Update local_database.dart GPS point schema**

In `gps_tracker/lib/shared/services/local_database.dart`, find the `local_gps_points` CREATE TABLE statement and add:

```sql
battery_level INTEGER,
```

Also update the insert and read methods for GPS points to include `battery_level`.

**Step 4: Update sync_service.dart to include battery_level in sync payload**

In `gps_tracker/lib/features/shifts/services/sync_service.dart`, find where GPS points are serialized for the `sync_gps_points` RPC call. Add `'battery_level': point.batteryLevel` to the JSON map.

**Step 5: Verify**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors

**Step 6: Commit**

```bash
cd gps_tracker
git add lib/shared/services/battery_service.dart \
        lib/features/tracking/services/background_tracking_service.dart \
        lib/shared/services/local_database.dart \
        lib/features/shifts/services/sync_service.dart
git commit -m "feat: capture battery level with every GPS point"
```

---

### Task 6: Add app lifecycle logging

**Files:**
- Modify: `gps_tracker/lib/app.dart`

**Step 1: Find the existing WidgetsBindingObserver**

In `app.dart`, the `_GpsTrackerAppState` class should already be a `ConsumerStatefulWidget` with state management. Look for `didChangeAppLifecycleState` — if it exists, enhance it. If not, add the mixin.

Add `WidgetsBindingObserver` mixin to the State class if not already present, and log all lifecycle transitions:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  super.didChangeAppLifecycleState(state);

  if (!DiagnosticLogger.isInitialized) return;

  switch (state) {
    case AppLifecycleState.paused:
      DiagnosticLogger.instance.lifecycle(
        Severity.info,
        'app_paused',
        metadata: {'timestamp': DateTime.now().toUtc().toIso8601String()},
      );
    case AppLifecycleState.resumed:
      DiagnosticLogger.instance.lifecycle(
        Severity.info,
        'app_resumed',
        metadata: {'timestamp': DateTime.now().toUtc().toIso8601String()},
      );
    case AppLifecycleState.detached:
      DiagnosticLogger.instance.lifecycle(
        Severity.warn,
        'app_detached',
        metadata: {'timestamp': DateTime.now().toUtc().toIso8601String()},
      );
    case AppLifecycleState.inactive:
      // Debug-level only (too frequent: calls, notifications, etc.)
      DiagnosticLogger.instance.lifecycle(
        Severity.debug,
        'app_inactive',
      );
    case AppLifecycleState.hidden:
      DiagnosticLogger.instance.lifecycle(
        Severity.debug,
        'app_hidden',
      );
  }
}
```

Don't forget `WidgetsBinding.instance.addObserver(this)` in `initState` and `removeObserver` in `dispose` if not already there.

**Step 2: Verify**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors

**Step 3: Commit**

```bash
cd gps_tracker
git add lib/app.dart
git commit -m "feat: log all app lifecycle transitions to DiagnosticLogger"
```

---

### Task 7: Add Crashlytics dSYM upload to Fastlane (iOS)

**Files:**
- Modify: `gps_tracker/ios/fastlane/Fastfile`

**Step 1: Add upload_symbols_to_crashlytics after build**

In the iOS Fastfile, find the `deploy` or `beta` lane. After the `build_app` step and before/after `upload_to_testflight`, add:

```ruby
# Upload dSYMs to Crashlytics for crash symbolication
upload_symbols_to_crashlytics(
  gsp_path: "./Runner/GoogleService-Info.plist"
)
```

Note: This requires the `fastlane-plugin-firebase_crashlytics` or the built-in `upload_symbols_to_crashlytics` action. If not available, use:

```ruby
# Alternative: use Firebase CLI
sh("cd .. && find build -name '*.dSYM' -exec /opt/homebrew/bin/firebase crashlytics:symbols:upload --app=YOUR_IOS_APP_ID {} \\;")
```

The exact approach depends on the current Fastfile structure — the implementer should read the Fastfile first and adapt.

**Step 2: Commit**

```bash
cd gps_tracker
git add ios/fastlane/Fastfile
git commit -m "chore: add Crashlytics dSYM upload to iOS Fastlane"
```

---

### Task 8: Add Crashlytics mapping upload to Fastlane (Android)

**Files:**
- Modify: `gps_tracker/android/app/build.gradle.kts`
- Potentially modify: `gps_tracker/android/fastlane/Fastfile`

**Step 1: Add Crashlytics Gradle plugin**

In `android/app/build.gradle.kts`, add the Crashlytics plugin. Check if `com.google.firebase.crashlytics` plugin is already applied. If not:

```kotlin
plugins {
    // ... existing plugins
    id("com.google.firebase.crashlytics")
}
```

And in `android/build.gradle.kts` (project-level), ensure the classpath/plugin is available:

```kotlin
plugins {
    // ... existing
    id("com.google.firebase.crashlytics") version "3.0.3" apply false
}
```

This automatically uploads ProGuard/R8 mapping files during release builds.

**Step 2: Verify Android build still works**

```bash
cd gps_tracker && flutter build apk --debug
```
Expected: Build succeeds

**Step 3: Commit**

```bash
cd gps_tracker
git add android/app/build.gradle.kts android/build.gradle.kts
git commit -m "chore: add Crashlytics Gradle plugin for Android mapping upload"
```

---

### Task 9: Final verification

**Step 1: Run full analysis**

```bash
cd gps_tracker && flutter analyze
```
Expected: No errors, no new warnings

**Step 2: Run existing tests**

```bash
cd gps_tracker && flutter test
```
Expected: All existing tests pass

**Step 3: Verify migration can be applied**

Apply migration 109 via Supabase MCP or verify SQL syntax is valid.

**Step 4: Manual test checklist**

- [ ] App starts without crash
- [ ] Clock-in works, GPS points are captured
- [ ] `flutter analyze` clean
- [ ] Firebase console shows Crashlytics enabled for the app
- [ ] Intentional test crash appears in Crashlytics dashboard
- [ ] Battery level appears in local GPS point data (check SQLite)
- [ ] Lifecycle events (app_paused, app_resumed) appear in diagnostic_events table

**Step 5: Final commit**

```bash
cd gps_tracker
git add -A
git commit -m "feat: Telemetry Phase 1 — Crashlytics + battery tracking + lifecycle logging

- Firebase Crashlytics for all Dart + native crash capture
- Battery level (0-100) captured with every GPS point
- App lifecycle transitions logged to DiagnosticLogger
- 8 new diagnostic categories (battery, crash, memory, service, satellite, doze, motion, metrickit)
- Migration 109: battery_level column + expanded diagnostic_logs categories
- dSYM/ProGuard upload in Fastlane for crash symbolication"
```
