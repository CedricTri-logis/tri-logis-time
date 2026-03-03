# Background Tracking Resilience v2 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce GPS data loss from 43% to ~5% by fixing DB contention, adding native GPS capture, and implementing server-initiated silent push wake.

**Architecture:** Three layered phases — Phase 1 fixes 1,351 DB errors/day with advisory locks and skipping active-shift trip detection. Phase 2 adds native GPS capture in Kotlin/Swift rescue mechanisms and a user-facing "shift not tracked" alert. Phase 3 adds Firebase Cloud Messaging for server-initiated wake of killed apps.

**Tech Stack:** PostgreSQL (advisory locks, pg_cron), Kotlin (FusedLocationProviderClient), Swift (CLLocationManager + UserDefaults), Flutter (flutter_local_notifications), Firebase (firebase_core, firebase_messaging), Supabase Edge Functions (Deno/TypeScript)

---

## Phase 1: DB Quick Wins

### Task 1: Advisory Lock on detect_trips

**Files:**
- Create: `supabase/migrations/126_advisory_locks_detect_trips.sql`

**Context:** `detect_trips` is called concurrently by 15+ phones. No concurrency protection exists. Today's logs show 790 statement timeouts + deadlocks from concurrent calls on the same shift. The function is defined across migrations 035, 071, 076, 113, 114.

**Step 1: Write the migration**

```sql
-- Migration: 126_advisory_locks_detect_trips.sql
-- Add advisory locks to detect_trips and detect_carpools to prevent deadlocks

-- 1. Add advisory lock to detect_trips
CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  -- Copy ALL existing variable declarations from current detect_trips
  -- (Do NOT modify any logic — only add the lock at the very top)
BEGIN
  -- NEW: Advisory lock prevents concurrent execution for the same shift
  PERFORM pg_advisory_xact_lock(hashtext(p_shift_id::text));

  -- ... rest of existing detect_trips body unchanged ...
END;
$$;

-- 2. Add advisory lock to detect_carpools
CREATE OR REPLACE FUNCTION detect_carpools(p_date DATE)
RETURNS TABLE(carpool_group_id UUID, member_count INT, trip_date DATE)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- NEW: Advisory lock prevents concurrent execution for the same date
  PERFORM pg_advisory_xact_lock(hashtext('carpools_' || p_date::text));

  -- ... rest of existing detect_carpools body unchanged ...
END;
$$;
```

**IMPORTANT:** The migration must `CREATE OR REPLACE` the full function body. You need to read the current function definitions first:

```sql
-- Run these to get the current function bodies:
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'detect_trips';
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'detect_carpools';
```

Then add `PERFORM pg_advisory_xact_lock(...)` as the FIRST statement inside the `BEGIN` block, before any other logic.

**Step 2: Apply the migration**

Use the Supabase MCP tool `apply_migration` to apply it to the production database. Verify no errors.

**Step 3: Verify the lock works**

```sql
-- Check the function was replaced successfully
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'detect_trips' LIMIT 1;
-- Should show pg_advisory_xact_lock as first statement in BEGIN block
```

**Step 4: Commit**

```bash
git add supabase/migrations/126_advisory_locks_detect_trips.sql
git commit -m "feat: add advisory locks to detect_trips and detect_carpools

Prevents deadlocks from concurrent execution. Uses pg_advisory_xact_lock
keyed on shift_id (detect_trips) and date (detect_carpools). Lock is
auto-released at transaction end."
```

---

### Task 2: Skip detect_trips During Active Shifts

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart:391-410`

**Context:** `_triggerTripDetection` at line 391 calls `detect_trips` for both the active shift (line 396) AND completed shifts (line 422). The active shift call is wasteful — trips aren't needed until after clock-out.

**Step 1: Remove the active shift detect_trips call**

In `sync_service.dart`, find the `_triggerTripDetection` method (line 391). Remove or comment out the active shift detect_trips block (lines 396-410) while keeping the completed shift re-detection (lines 422-437).

The active shift block looks like:
```dart
// REMOVE THIS BLOCK (lines ~396-410):
_supabase.rpc('detect_trips', params: {
  'p_shift_id': activeShift.serverId,
}).then((_) {
  // ... carpool detection for active shift
}).catchError((e) {
  DiagnosticLogger.instance?.log(
    category: 'sync',
    severity: 'warn',
    message: 'Active shift trip detection failed',
    // ...
  );
});
```

Keep the completed shift re-detection block (lines ~422-437) unchanged.

**Step 2: Verify the app compiles**

```bash
cd gps_tracker && flutter analyze
```

Expected: No errors related to sync_service.dart.

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/sync_service.dart
git commit -m "perf: skip detect_trips during active shifts

Trip detection is only needed after clock-out for supervisor approvals.
Removing the active-shift call eliminates ~50% of detect_trips DB load
and prevents statement timeouts during peak sync hours."
```

---

### Task 3: Reduce Stationary Interval to 60 Seconds

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart:15`

**Context:** Line 15 defines `_stationaryIntervalSeconds = 120`. This means in stationary mode, GPS points are captured every 2 minutes. With a 45-second GPS loss threshold, we can't distinguish "normal stationary" from "app killed" until 240s+. Reducing to 60s halves that detection window.

**Step 1: Change the constant**

At line 15 of `gps_tracking_handler.dart`, change:
```dart
// Before:
int _stationaryIntervalSeconds = 120;

// After:
int _stationaryIntervalSeconds = 60;
```

**Step 2: Verify the app compiles**

```bash
cd gps_tracker && flutter analyze
```

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart
git commit -m "feat: reduce stationary GPS interval from 120s to 60s

Halves the gap detection window. With 120s intervals, can't distinguish
normal stationary from dead app before 240s+. With 60s, detection at 120s.
Negligible battery impact — iOS GPS chip already fires continuously
(distanceFilter: 0), Android interval hint already set to 15s."
```

---

### Task 4: Deploy Phase 1 and Verify

**Step 1: Deploy to TestFlight and Google Play**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
./deploy.sh
```

**Step 2: Monitor diagnostic logs after deploy**

Wait 30-60 minutes after employees update, then check:

```sql
-- Should see drastically fewer sync errors
SELECT message, count(*) as cnt
FROM diagnostic_logs
WHERE created_at >= now() - interval '1 hour'
  AND event_category = 'sync'
  AND severity = 'warn'
GROUP BY message
ORDER BY cnt DESC;
```

Expected: "Trip re-detection failed" and "Active shift trip detection failed" counts should drop to near zero.

---

## Phase 2: Native Client Resilience

### Task 5: Native GPS Buffer — Android (Kotlin)

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsBuffer.kt`
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt:179-218`

**Context:** The rescue alarm fires every 45s and restarts the Flutter foreground service, but the GPS stream inside doesn't always recover. We add native GPS capture directly in Kotlin so even with a dead Flutter engine, we get points.

**Step 1: Create NativeGpsBuffer helper class**

Create `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsBuffer.kt`:

```kotlin
package ca.trilogis.gpstracker

import android.content.Context
import android.location.Location
import org.json.JSONArray
import org.json.JSONObject

/**
 * Stores GPS points captured natively (outside Flutter) in SharedPreferences.
 * Flutter reads and drains this buffer on resume via MethodChannel.
 */
object NativeGpsBuffer {
    private const val PREFS_NAME = "native_gps_buffer"
    private const val KEY_POINTS = "points"
    private const val MAX_POINTS = 100

    fun save(context: Context, shiftId: String, location: Location) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val points = getPointsArray(prefs.getString(KEY_POINTS, "[]")!!)

        val point = JSONObject().apply {
            put("shift_id", shiftId)
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("accuracy", location.accuracy.toDouble())
            put("altitude", location.altitude)
            put("speed", location.speed.toDouble())
            put("heading", location.bearing.toDouble())
            put("captured_at", System.currentTimeMillis())
            put("source", "native_rescue")
        }

        points.put(point)

        // Trim to max size (remove oldest first)
        while (points.length() > MAX_POINTS) {
            points.remove(0)
        }

        prefs.edit().putString(KEY_POINTS, points.toString()).apply()
    }

    fun drain(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_POINTS, "[]")!!
        prefs.edit().putString(KEY_POINTS, "[]").apply()
        return json
    }

    fun count(context: Context): Int {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return getPointsArray(prefs.getString(KEY_POINTS, "[]")!!).length()
    }

    private fun getPointsArray(json: String): JSONArray {
        return try { JSONArray(json) } catch (_: Exception) { JSONArray() }
    }
}
```

**Step 2: Add native GPS capture to TrackingRescueReceiver**

In `TrackingRescueReceiver.kt`, modify the `onReceive` method (lines 179-218). After the existing FFT restart logic, add native GPS capture:

```kotlin
// In onReceive(), after the FFT restart block and before scheduling next alarm:

// Capture GPS point natively as backup
try {
    val fusedClient = com.google.android.gms.location.LocationServices
        .getFusedLocationProviderClient(context)
    val cancellationSource = com.google.android.gms.tasks.CancellationTokenSource()

    fusedClient.getCurrentLocation(
        com.google.android.gms.location.Priority.PRIORITY_HIGH_ACCURACY,
        cancellationSource.token
    ).addOnSuccessListener { location ->
        if (location != null && shiftId != null) {
            NativeGpsBuffer.save(context, shiftId, location)
            writeBreadcrumb(context, "rescue", "native_gps_captured", shiftId)
        }
    }.addOnFailureListener {
        // Fail silently — rescue alarm continues regardless
    }

    // Cancel after 10 seconds to avoid hanging
    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
        cancellationSource.cancel()
    }, 10_000)
} catch (_: SecurityException) {
    // Location permission not granted — skip native capture
} catch (_: Exception) {
    // Any other error — skip native capture
}
```

**Step 3: Add MethodChannel to drain buffer from Flutter**

In `MainActivity.kt`, add a handler in the device manufacturer channel (around line 100):

```kotlin
"drainNativeGpsBuffer" -> {
    val json = NativeGpsBuffer.drain(this)
    result.success(json)
}
"getNativeGpsBufferCount" -> {
    val count = NativeGpsBuffer.count(this)
    result.success(count)
}
```

**Step 4: Add play-services-location dependency**

In `gps_tracker/android/app/build.gradle.kts`, add to the dependencies block:

```kotlin
implementation("com.google.android.gms:play-services-location:21.3.0")
```

**Step 5: Verify Android builds**

```bash
cd gps_tracker && flutter build apk --debug
```

**Step 6: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsBuffer.kt
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git add gps_tracker/android/app/build.gradle.kts
git commit -m "feat: native GPS capture in Android rescue alarm

When the rescue alarm fires and the Flutter service is dead, capture a
GPS point directly via FusedLocationProviderClient in Kotlin. Points are
buffered in SharedPreferences (max 100) and drained by Flutter on resume.
This fills GPS gaps even when the Flutter engine can't restart."
```

---

### Task 6: Native GPS Buffer — iOS (Swift)

**Files:**
- Create: `gps_tracker/ios/Runner/NativeGpsBuffer.swift`
- Modify: `gps_tracker/ios/Runner/SignificantLocationPlugin.swift:63-75`

**Context:** When SLC fires `didUpdateLocations`, it sends the position to Flutter via MethodChannel. If the Flutter engine is dead, the MethodChannel fails silently. We save natively to UserDefaults as backup.

**Step 1: Create NativeGpsBuffer helper class**

Create `gps_tracker/ios/Runner/NativeGpsBuffer.swift`:

```swift
import Foundation
import CoreLocation

class NativeGpsBuffer {
    static let shared = NativeGpsBuffer()
    private let key = "native_gps_buffer_points"
    private let maxPoints = 100

    func save(location: CLLocation, shiftId: String) {
        var points = load()

        let point: [String: Any] = [
            "shift_id": shiftId,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "speed": max(0, location.speed),
            "heading": max(0, location.course),
            "captured_at": Int(location.timestamp.timeIntervalSince1970 * 1000),
            "source": "native_slc"
        ]

        points.append(point)

        // Trim to max size
        if points.count > maxPoints {
            points = Array(points.suffix(maxPoints))
        }

        if let data = try? JSONSerialization.data(withJSONObject: points),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }

    func drain() -> String {
        let points = load()
        UserDefaults.standard.set("[]", forKey: key)
        if let data = try? JSONSerialization.data(withJSONObject: points),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    func count() -> Int {
        return load().count
    }

    private func load() -> [[String: Any]] {
        guard let json = UserDefaults.standard.string(forKey: key),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }
}
```

**Step 2: Add native save to SignificantLocationPlugin**

In `SignificantLocationPlugin.swift`, modify the `didUpdateLocations` delegate method (lines 63-75). After the existing MethodChannel call, add:

```swift
// After: channel.invokeMethod("onSignificantLocationChange", arguments: data)
// Add:
if let shiftId = UserDefaults.standard.string(forKey: "flutter.shift_id") {
    NativeGpsBuffer.shared.save(location: location, shiftId: shiftId)
}
```

Note: The shift_id is stored by FlutterForegroundTask in UserDefaults with the "flutter." prefix.

**Step 3: Add MethodChannel to drain buffer from Flutter**

In `AppDelegate.swift`, register a method channel handler in `application(_:didFinishLaunchingWithOptions:)`:

```swift
let nativeGpsChannel = FlutterMethodChannel(
    name: "gps_tracker/native_gps_buffer",
    binaryMessenger: controller.binaryMessenger
)
nativeGpsChannel.setMethodCallHandler { (call, result) in
    switch call.method {
    case "drain":
        result(NativeGpsBuffer.shared.drain())
    case "count":
        result(NativeGpsBuffer.shared.count())
    default:
        result(FlutterMethodNotImplemented)
    }
}
```

**Step 4: Verify iOS builds**

```bash
cd gps_tracker && flutter build ios --debug --no-codesign
```

**Step 5: Commit**

```bash
git add gps_tracker/ios/Runner/NativeGpsBuffer.swift
git add gps_tracker/ios/Runner/SignificantLocationPlugin.swift
git add gps_tracker/ios/Runner/AppDelegate.swift
git commit -m "feat: native GPS buffer in iOS SLC callback

When Significant Location Change fires, save GPS point to UserDefaults
in addition to MethodChannel (which fails if Flutter engine is dead).
Points buffered (max 100) and drained by Flutter on resume."
```

---

### Task 7: Flutter — Drain Native GPS Buffers on Resume

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart`

**Context:** Both Android and iOS now save native GPS points to platform storage. Flutter needs to read and integrate these points into the normal sync pipeline on resume.

**Step 1: Add native buffer drain method**

Add a new method to `sync_service.dart` that reads native GPS buffers via MethodChannel and inserts them into the local SQLCipher database:

```dart
/// Drains native GPS buffers (Android SharedPreferences / iOS UserDefaults)
/// and inserts points into local SQLCipher for normal sync pipeline.
Future<int> _drainNativeGpsBuffers() async {
  try {
    String? json;

    if (Platform.isAndroid) {
      json = await const MethodChannel('gps_tracker/device_manufacturer')
          .invokeMethod<String>('drainNativeGpsBuffer');
    } else if (Platform.isIOS) {
      json = await const MethodChannel('gps_tracker/native_gps_buffer')
          .invokeMethod<String>('drain');
    }

    if (json == null || json == '[]') return 0;

    final List<dynamic> points = jsonDecode(json);
    if (points.isEmpty) return 0;

    int inserted = 0;
    for (final point in points) {
      await _localDb.insertGpsPoint(
        shiftId: point['shift_id'],
        latitude: (point['latitude'] as num).toDouble(),
        longitude: (point['longitude'] as num).toDouble(),
        accuracy: (point['accuracy'] as num).toDouble(),
        altitude: point['altitude'] != null ? (point['altitude'] as num).toDouble() : null,
        speed: point['speed'] != null ? (point['speed'] as num).toDouble() : null,
        heading: point['heading'] != null ? (point['heading'] as num).toDouble() : null,
        capturedAt: DateTime.fromMillisecondsSinceEpoch(point['captured_at'] as int),
      );
      inserted++;
    }

    if (inserted > 0) {
      DiagnosticLogger.instance?.log(
        category: 'gps',
        severity: 'info',
        message: 'Drained native GPS buffer',
        metadata: {'count': inserted, 'source': points.first['source']},
      );
    }

    return inserted;
  } catch (e) {
    DiagnosticLogger.instance?.log(
      category: 'gps',
      severity: 'warn',
      message: 'Failed to drain native GPS buffer',
      metadata: {'error': e.toString()},
    );
    return 0;
  }
}
```

**Step 2: Call it at the beginning of the sync cycle**

In the main sync method, add the drain call as Step 0 (before syncing shifts):

```dart
// At the top of the sync cycle, before Step 1 (sync shifts):
await _drainNativeGpsBuffers();
```

**Step 3: Verify the app compiles**

```bash
cd gps_tracker && flutter analyze
```

**Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/services/sync_service.dart
git commit -m "feat: drain native GPS buffers at sync start

Reads GPS points captured natively by Android rescue alarm and iOS SLC
from SharedPreferences/UserDefaults, inserts into SQLCipher for normal
sync pipeline. Called as Step 0 before shift sync."
```

---

### Task 8: "Shift Not Tracked" Alert Notification

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart:377-415`

**Context:** The `onRepeatEvent` method fires every 30s. We already check GPS loss at line 398. If GPS is lost for > 5 minutes, we show a local notification telling the employee their shift isn't being tracked.

**Step 1: Add notification logic to onRepeatEvent**

In `gps_tracking_handler.dart`, add after the existing `_checkGpsLoss(timestamp)` call (line 398):

```dart
// After _checkGpsLoss(timestamp):
_checkAndNotifyGpsAlert(timestamp);
```

Add the new method:

```dart
static const _gpsAlertThreshold = Duration(minutes: 5);
static const _gpsAlertNotificationId = 9999; // Separate from foreground service
bool _gpsAlertShown = false;

void _checkAndNotifyGpsAlert(DateTime now) {
  if (_lastSuccessfulPositionAt == null) return;

  final elapsed = now.difference(_lastSuccessfulPositionAt!);

  if (elapsed >= _gpsAlertThreshold && !_gpsAlertShown) {
    _gpsAlertShown = true;
    // Send message to main isolate to show notification
    FlutterForegroundTask.sendDataToMain({
      'type': 'gps_alert',
      'action': 'show',
      'gap_minutes': elapsed.inMinutes,
    });
  } else if (elapsed < _gpsAlertThreshold && _gpsAlertShown) {
    _gpsAlertShown = false;
    // GPS restored — dismiss alert
    FlutterForegroundTask.sendDataToMain({
      'type': 'gps_alert',
      'action': 'dismiss',
    });
  }
}
```

**Step 2: Handle in tracking_provider.dart**

In the main isolate's message handler (tracking_provider.dart), handle the `gps_alert` message type:

```dart
case 'gps_alert':
  final action = data['action'] as String;
  if (action == 'show') {
    await NotificationService().showGpsAlertNotification(
      gapMinutes: data['gap_minutes'] as int,
    );
  } else if (action == 'dismiss') {
    await NotificationService().dismissGpsAlertNotification();
  }
```

**Step 3: Add notification methods to NotificationService**

In the notification service, add:

```dart
static const _gpsAlertId = 9999;

Future<void> showGpsAlertNotification({required int gapMinutes}) async {
  await _plugin.show(
    _gpsAlertId,
    'Suivi de position interrompu',
    'Votre quart n\'est plus suivi. Appuyez pour reprendre.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'gps_alert',
        'Alerte GPS',
        channelDescription: 'Alerte quand le suivi GPS est interrompu',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    ),
  );
}

Future<void> dismissGpsAlertNotification() async {
  await _plugin.cancel(_gpsAlertId);
}
```

**Step 4: Reset alert on GPS point capture**

In `gps_tracking_handler.dart`, when a GPS point is successfully captured, reset the alert:

```dart
// In the position callback, after saving the point:
if (_gpsAlertShown) {
  _gpsAlertShown = false;
  FlutterForegroundTask.sendDataToMain({
    'type': 'gps_alert',
    'action': 'dismiss',
  });
}
```

**Step 5: Verify the app compiles**

```bash
cd gps_tracker && flutter analyze
```

**Step 6: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart
git add gps_tracker/lib/features/tracking/providers/tracking_provider.dart
git add gps_tracker/lib/shared/services/notification_service.dart
git commit -m "feat: 'shift not tracked' alert when GPS lost > 5 min

Shows a local notification 'Suivi de position interrompu — Votre quart
n'est plus suivi. Appuyez pour reprendre.' when no GPS point captured
for 5+ minutes. Auto-dismissed when GPS resumes. Separate notification
ID from the foreground service notification."
```

---

### Task 9: Deploy Phase 2 and Verify

**Step 1: Deploy**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
./deploy.sh
```

**Step 2: Verify native GPS buffer works**

After deploy, check diagnostic logs for native buffer drains:

```sql
SELECT message, metadata, created_at
FROM diagnostic_logs
WHERE message IN ('Drained native GPS buffer', 'native_gps_captured')
  AND created_at >= now() - interval '4 hours'
ORDER BY created_at DESC;
```

---

## Phase 3: Firebase Silent Push

### Task 10: Firebase Project Setup

**This task requires manual steps in the Firebase Console.**

**Step 1: Create or find Firebase project**

1. Go to https://console.firebase.google.com/
2. Check if a project exists for GPS Tracker / Tri-Logis
3. If not, create one: "GPS Tracker" in the Canada region
4. Enable Cloud Messaging (FCM) in project settings

**Step 2: Add Android app**

1. Package name: `ca.trilogis.gpstracker` (check AndroidManifest.xml)
2. Download `google-services.json`
3. Place at: `gps_tracker/android/app/google-services.json`

**Step 3: Add iOS app**

1. Bundle ID: check `ios/Runner.xcodeproj` or Info.plist for the bundle identifier
2. Download `GoogleService-Info.plist`
3. Place at: `gps_tracker/ios/Runner/GoogleService-Info.plist`

**Step 4: Get service account key**

1. Firebase Console → Project Settings → Service Accounts
2. Generate new private key (JSON)
3. Save locally — will be added as Supabase secret in Task 13

**Step 5: Commit config files**

```bash
git add gps_tracker/android/app/google-services.json
git add gps_tracker/ios/Runner/GoogleService-Info.plist
git commit -m "chore: add Firebase configuration files"
```

---

### Task 11: Flutter Firebase Integration

**Files:**
- Modify: `gps_tracker/pubspec.yaml`
- Modify: `gps_tracker/android/app/build.gradle.kts`
- Modify: `gps_tracker/android/build.gradle.kts` (project-level)
- Modify: `gps_tracker/lib/main.dart:76-80`
- Modify: `gps_tracker/lib/features/auth/services/auth_service.dart:50-68`

**Step 1: Add dependencies**

In `gps_tracker/pubspec.yaml`, add:
```yaml
  firebase_core: ^3.12.0
  firebase_messaging: ^15.2.0
```

**Step 2: Add Google Services plugin (Android)**

In `gps_tracker/android/app/build.gradle.kts`:
```kotlin
plugins {
    // ... existing plugins
    id("com.google.gms.google-services")
}
```

In `gps_tracker/android/build.gradle.kts` (project-level):
```kotlin
plugins {
    // ... existing plugins
    id("com.google.gms.google-services") version "4.4.2" apply false
}
```

**Step 3: Initialize Firebase in main.dart**

In `main.dart`, add Firebase initialization BEFORE Supabase initialization (around line 76):

```dart
import 'package:firebase_core/firebase_core.dart';

// In main():
await Firebase.initializeApp();

// Existing Supabase init follows...
await Supabase.initialize(...);
```

**Step 4: Save FCM token at login**

In `auth_service.dart`, after successful sign-in (line 55), add FCM token registration:

```dart
// After: final response = await _client.auth.signInWithPassword(...)
// Add:
await _registerFcmToken();
```

Add the helper method:
```dart
Future<void> _registerFcmToken() async {
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _client.from('employee_profiles').update({
        'fcm_token': token,
      }).eq('id', _client.auth.currentUser!.id);
    }

    // Listen for token refresh
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      try {
        await _client.from('employee_profiles').update({
          'fcm_token': newToken,
        }).eq('id', _client.auth.currentUser!.id);
      } catch (_) {}
    });
  } catch (_) {
    // FCM token registration is non-critical — don't block auth
  }
}
```

Do the same after `verifyOtp` (line 198) and `restoreSession` (line 221).

**Step 5: Add background message handler**

In `main.dart`, add the Firebase messaging background handler:

```dart
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  // Check if this is a wake push
  if (message.data['type'] == 'wake') {
    // Check for active shift
    final shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    if (shiftId != null) {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        // Restart tracking
        await FlutterForegroundTask.startService(
          notificationTitle: 'Suivi de position actif',
          notificationText: 'Suivi de votre position pendant le quart',
          callback: startCallback,
        );
      }
    }
  }
}

// In main():
FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
```

**Step 6: Verify both platforms build**

```bash
cd gps_tracker && flutter build apk --debug
cd gps_tracker && flutter build ios --debug --no-codesign
```

**Step 7: Commit**

```bash
git add gps_tracker/pubspec.yaml
git add gps_tracker/android/app/build.gradle.kts
git add gps_tracker/android/build.gradle.kts
git add gps_tracker/lib/main.dart
git add gps_tracker/lib/features/auth/services/auth_service.dart
git commit -m "feat: Firebase integration with FCM token registration

Adds firebase_core + firebase_messaging. Registers FCM token to
employee_profiles at login/OTP/session restore. Background handler
restarts tracking on wake push from server."
```

---

### Task 12: Database Migration — FCM Token + Wake Push Tracking

**Files:**
- Create: `supabase/migrations/127_fcm_wake_push.sql`

**Step 1: Write the migration**

```sql
-- Migration: 127_fcm_wake_push.sql
-- Add FCM token storage and wake push throttling

-- 1. Add columns to employee_profiles
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS fcm_token TEXT,
  ADD COLUMN IF NOT EXISTS last_wake_push_at TIMESTAMPTZ;

-- 2. Create function to find stale devices
CREATE OR REPLACE FUNCTION get_stale_active_devices()
RETURNS TABLE(
  employee_id UUID,
  fcm_token TEXT,
  shift_id UUID,
  minutes_since_heartbeat INT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT
    s.employee_id,
    ep.fcm_token,
    s.id as shift_id,
    EXTRACT(EPOCH FROM (now() - s.last_heartbeat_at))::int / 60 as minutes_since_heartbeat
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.status = 'active'
    AND s.last_heartbeat_at < now() - interval '5 minutes'
    AND ep.fcm_token IS NOT NULL
    AND (ep.last_wake_push_at IS NULL
         OR ep.last_wake_push_at < now() - interval '5 minutes');
$$;

-- 3. Create function to record wake push sent
CREATE OR REPLACE FUNCTION record_wake_push(p_employee_id UUID)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE employee_profiles
  SET last_wake_push_at = now()
  WHERE id = p_employee_id;
$$;
```

**Step 2: Apply the migration**

Use the Supabase MCP tool `apply_migration`.

**Step 3: Commit**

```bash
git add supabase/migrations/127_fcm_wake_push.sql
git commit -m "feat: add FCM token and wake push tracking columns

Adds fcm_token and last_wake_push_at to employee_profiles.
get_stale_active_devices() finds active shifts with stale heartbeats
(>5 min) and valid FCM tokens. Throttled to max 1 push per 5 min."
```

---

### Task 13: Supabase Edge Function — send-wake-push

**Files:**
- Create: `supabase/functions/send-wake-push/index.ts`

**Step 1: Set Firebase secret**

```bash
supabase secrets set FIREBASE_SERVICE_ACCOUNT_KEY='<contents of firebase service account JSON>'
```

**Step 2: Create the Edge Function**

Create `supabase/functions/send-wake-push/index.ts`:

```typescript
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FIREBASE_SA_KEY = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_KEY")!);

// Get OAuth2 access token for FCM v1 API
async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = btoa(JSON.stringify({
    iss: FIREBASE_SA_KEY.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));

  // Sign JWT with service account private key
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(FIREBASE_SA_KEY.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claim}`)
  );

  const jwt = `${header}.${claim}.${btoa(String.fromCharCode(...new Uint8Array(signature)))}`;

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenRes.json();
  return tokenData.access_token;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function sendSilentPush(token: string, accessToken: string): Promise<boolean> {
  const projectId = FIREBASE_SA_KEY.project_id;
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          data: { type: "wake", timestamp: Date.now().toString() },
          android: { priority: "high" },
          apns: {
            headers: { "apns-priority": "10" },
            payload: { aps: { "content-available": 1 } },
          },
        },
      }),
    }
  );

  return res.ok;
}

Deno.serve(async (req: Request) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Find stale devices
    const { data: staleDevices, error } = await supabase.rpc("get_stale_active_devices");
    if (error) throw error;
    if (!staleDevices || staleDevices.length === 0) {
      return new Response(JSON.stringify({ sent: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const accessToken = await getAccessToken();
    let sent = 0;

    for (const device of staleDevices) {
      const success = await sendSilentPush(device.fcm_token, accessToken);
      if (success) {
        await supabase.rpc("record_wake_push", { p_employee_id: device.employee_id });
        sent++;
      }
    }

    return new Response(JSON.stringify({ sent, total: staleDevices.length }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
```

**Step 3: Deploy the Edge Function**

Use the Supabase MCP tool `deploy_edge_function` with `verify_jwt: false` (called by pg_cron, not user-facing).

**Step 4: Test manually**

```bash
curl -X POST https://xdyzdclwvhkfwbkrdsiz.supabase.co/functions/v1/send-wake-push
```

Expected: `{"sent": 0}` if no stale devices, or `{"sent": N}` if there are.

**Step 5: Commit**

```bash
git add supabase/functions/send-wake-push/index.ts
git commit -m "feat: Edge Function to send silent wake pushes to stale devices

Queries get_stale_active_devices() for active shifts with heartbeat > 5 min,
sends FCM silent push (data-only for Android, content-available for iOS).
Records last_wake_push_at for throttling (max 1 per 5 min per employee)."
```

---

### Task 14: pg_cron Job — Wake Stale Devices

**Files:**
- Create: `supabase/migrations/128_wake_stale_devices_cron.sql`

**Step 1: Write the migration**

```sql
-- Migration: 128_wake_stale_devices_cron.sql
-- pg_cron job to call send-wake-push Edge Function every 2 minutes

SELECT cron.schedule(
  'wake-stale-devices',
  '*/2 * * * *',  -- Every 2 minutes
  $$
  SELECT net.http_post(
    url := current_setting('app.settings.service_url') || '/functions/v1/send-wake-push',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
```

**Note:** If `net.http_post` is not available (requires `pg_net` extension), use `extensions.http_post` or check which HTTP extension is enabled. Alternatively, call the Edge Function via `supabase_functions.invoke`.

**Step 2: Apply the migration**

Use the Supabase MCP tool `apply_migration`.

**Step 3: Verify the cron job is registered**

```sql
SELECT * FROM cron.job WHERE jobname = 'wake-stale-devices';
```

**Step 4: Commit**

```bash
git add supabase/migrations/128_wake_stale_devices_cron.sql
git commit -m "feat: pg_cron job to wake stale devices every 2 minutes

Calls send-wake-push Edge Function every 2 minutes. The function finds
active shifts with heartbeat > 5 min and sends silent FCM push to
wake the killed app."
```

---

### Task 15: Deploy Phase 3 and Full Verification

**Step 1: Deploy**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
./deploy.sh
```

**Step 2: Verify FCM tokens are being saved**

```sql
SELECT full_name, fcm_token IS NOT NULL as has_token, last_wake_push_at
FROM employee_profiles
WHERE role = 'employee'
ORDER BY full_name;
```

After employees update the app and log in, `has_token` should become `true`.

**Step 3: Verify wake pushes are being sent**

```sql
SELECT full_name, last_wake_push_at
FROM employee_profiles
WHERE last_wake_push_at IS NOT NULL
ORDER BY last_wake_push_at DESC;
```

**Step 4: Monitor the full resilience pipeline**

```sql
-- Full health check: stale devices vs wake pushes
SELECT
  ep.full_name,
  s.status,
  round(EXTRACT(EPOCH FROM (now() - s.last_heartbeat_at))/60) as min_since_heartbeat,
  ep.fcm_token IS NOT NULL as has_fcm,
  ep.last_wake_push_at,
  (SELECT count(*) FROM gps_points gp WHERE gp.shift_id = s.id) as gps_count
FROM shifts s
JOIN employee_profiles ep ON ep.id = s.employee_id
WHERE s.status = 'active'
ORDER BY s.last_heartbeat_at ASC;
```

**Expected outcome after full deployment:**
- DB errors: ~0 (advisory locks)
- GPS gaps during stationary: ~60s instead of ~120s
- Killed apps: get native GPS points every 45s (Android) or on movement (iOS)
- Killed apps stale > 5 min: server sends silent push to wake them
- User notification: "Votre quart n'est plus suivi" after 5 min gap
