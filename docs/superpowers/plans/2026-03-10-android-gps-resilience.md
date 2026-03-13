# Android GPS Tracking Resilience — Fix Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three issues causing GPS gaps on certain Android devices: broken Firebase init (affects all users), native GPS buffer stuck on device (never synced until app reopens), and lack of proactive device health telemetry.

**Architecture:** Three independent fixes: (1) Guard FCM registration behind Firebase init state, (2) Add OkHttp-based direct Supabase sync from Kotlin rescue receiver, (3) Log battery/standby/manufacturer diagnostics at shift start.

**Tech Stack:** Kotlin (Android native), Dart/Flutter, OkHttp 4.x, Supabase REST API, SharedPreferences

---

## Chunk 1: Fix Firebase Init Race Condition

### Task 1: Guard FCM registration in app.dart

The `[core/no-app]` error occurs because `FcmService().registerToken()` is called in `app.dart` before `Firebase.initializeApp()` completes (Firebase init is intentionally deferred 3 seconds in main.dart).

**Files:**
- Modify: `gps_tracker/lib/app.dart` (~line 388-396)
- Modify: `gps_tracker/lib/main.dart` (expose `_firebaseInitialized` flag)
- Modify: `gps_tracker/lib/shared/services/fcm_service.dart` (add init guard)

- [ ] **Step 1: Add a public Firebase init check to main.dart**

In `main.dart`, the `_firebaseInitialized` flag is private. Expose it:

```dart
// Near top of file, after existing globals
bool get isFirebaseInitialized => _firebaseInitialized;
```

- [ ] **Step 2: Guard registerToken() in fcm_service.dart**

At the top of `registerToken()`, add an early return if Firebase isn't ready:

```dart
import 'package:gps_tracker/main.dart' show isFirebaseInitialized;

Future<void> registerToken() async {
  // Firebase might not be initialized yet (deferred init strategy).
  // The retry after Firebase.initializeApp() in main.dart will call us again.
  if (!isFirebaseInitialized) return;
  // ... rest of existing code
}
```

Do the same for `listenForTokenRefresh()`:

```dart
void listenForTokenRefresh() {
  if (!isFirebaseInitialized) return;
  // ... rest of existing code
}
```

And for `initialize()`:

```dart
Future<void> initialize() async {
  if (!isFirebaseInitialized) return;
  // ... rest of existing code
}
```

- [ ] **Step 3: Remove the try/catch wrapper in app.dart**

In `app.dart` (~lines 388-396), the try/catch around FCM calls is now unnecessary since the guard handles it. Simplify:

```dart
// Before:
try {
  FcmService().registerToken();
  FcmService().listenForTokenRefresh();
} catch (_) {
  // Firebase not ready yet — will register on next build cycle
}

// After:
FcmService().registerToken();
FcmService().listenForTokenRefresh();
```

- [ ] **Step 4: Verify the retry path in main.dart**

Confirm that `_initializeFirebase()` (line 362-369) already calls:
```dart
FcmService().initialize();
FcmService().registerToken();
FcmService().listenForTokenRefresh();
```
This is the real registration point — the app.dart call is just an early attempt that should silently no-op if Firebase isn't ready.

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/main.dart gps_tracker/lib/app.dart gps_tracker/lib/shared/services/fcm_service.dart
git commit -m "fix: guard FCM registration behind Firebase init state

Firebase.initializeApp() is deferred 3s to avoid iOS Jetsam kills.
FcmService methods called before init now silently return instead of
throwing [core/no-app]. The retry after init completes handles registration."
```

---

## Chunk 2: Native GPS Buffer Direct Sync from Kotlin

When the Dart engine is dead but the AlarmManager rescue chain is still running, GPS points accumulate in the native SharedPreferences buffer. Currently these are only synced when the user reopens the app. This fix adds a direct HTTP POST to Supabase from the rescue receiver.

### Task 2: Add OkHttp dependency

**Files:**
- Modify: `gps_tracker/android/app/build.gradle.kts` (add OkHttp)

- [ ] **Step 1: Add OkHttp to dependencies**

In `build.gradle.kts`, add to the `dependencies` block:

```kotlin
implementation("com.squareup.okhttp3:okhttp:4.12.0")
```

- [ ] **Step 2: Run gradle sync to verify**

```bash
cd gps_tracker && flutter pub get
```

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/android/app/build.gradle.kts
git commit -m "chore: add OkHttp 4.12.0 for native GPS sync"
```

### Task 3: Store Supabase credentials in SharedPreferences from Dart

The native code needs the Supabase URL, anon key, and employee_id to POST GPS points. Pass these from Dart when tracking starts.

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

- [ ] **Step 1: Find the startTracking() method**

Read the file to find where shift_id and employee_id are saved to FlutterForegroundTask SharedPreferences before starting the service.

- [ ] **Step 2: Add Supabase credentials to the saved data**

After the existing `FlutterForegroundTask.saveData()` calls for shift_id and employee_id, add:

```dart
import 'package:gps_tracker/core/config/env_config.dart';

// Save Supabase credentials for native direct sync
await FlutterForegroundTask.saveData(
  key: 'supabase_url',
  value: EnvConfig.supabaseUrl,
);
await FlutterForegroundTask.saveData(
  key: 'supabase_anon_key',
  value: EnvConfig.supabaseAnonKey,
);
```

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/background_tracking_service.dart
git commit -m "feat: pass Supabase credentials to native SharedPreferences for direct sync"
```

### Task 4: Create NativeGpsSyncer.kt

A new Kotlin class that POSTs buffered GPS points directly to Supabase using OkHttp. Called by the rescue receiver after capturing a native GPS point.

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsSyncer.kt`

- [ ] **Step 1: Create NativeGpsSyncer.kt**

```kotlin
package ca.trilogis.gpstracker

import android.content.Context
import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Syncs native GPS buffer directly to Supabase via HTTP POST.
 * Used by TrackingRescueReceiver when the Dart engine is dead.
 *
 * Reads Supabase credentials from FlutterForegroundTask SharedPreferences
 * (saved by BackgroundTrackingService.startTracking() on the Dart side).
 */
object NativeGpsSyncer {
    private const val TAG = "NativeGpsSyncer"
    private const val FGT_PREFS = "FlutterSharedPreferences"
    private const val KEY_PREFIX = "flutter.com.pravera.flutter_foreground_task.prefs."

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /**
     * Attempt to sync all buffered native GPS points to Supabase.
     * Returns the number of points successfully synced (and removed from buffer).
     * Returns 0 on any failure — points remain in buffer for later drain.
     *
     * Runs on a background thread (called from rescue receiver).
     */
    fun syncBufferedPoints(context: Context): Int {
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)

        val supabaseUrl = prefs.getString("${KEY_PREFIX}supabase_url", null)
        val supabaseKey = prefs.getString("${KEY_PREFIX}supabase_anon_key", null)
        val employeeId = prefs.getString("${KEY_PREFIX}employee_id", null)

        if (supabaseUrl == null || supabaseKey == null || employeeId == null) {
            Log.d(TAG, "Missing Supabase credentials or employee_id — skipping native sync")
            return 0
        }

        // Read buffer without draining (we drain only after successful POST)
        val bufferPrefs = context.getSharedPreferences("native_gps_buffer", Context.MODE_PRIVATE)
        val json = bufferPrefs.getString("points", null)
        if (json.isNullOrEmpty() || json == "[]") return 0

        return try {
            val points = JSONArray(json)
            if (points.length() == 0) return 0

            // Build the insert payload for Supabase REST API (POST /rest/v1/gps_points)
            val payload = JSONArray()
            for (i in 0 until points.length()) {
                val p = points.getJSONObject(i)
                val row = JSONObject().apply {
                    put("shift_id", p.getString("shift_id"))
                    put("employee_id", employeeId)
                    put("latitude", p.getDouble("latitude"))
                    put("longitude", p.getDouble("longitude"))
                    put("accuracy", p.getDouble("accuracy"))
                    put("speed", p.optDouble("speed", 0.0))
                    put("altitude", p.optDouble("altitude", 0.0))
                    put("heading", p.optDouble("heading", 0.0))
                    // captured_at is millis — convert to ISO 8601
                    val capturedMs = p.getLong("captured_at")
                    val iso = java.text.SimpleDateFormat(
                        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                        java.util.Locale.US
                    ).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }.format(java.util.Date(capturedMs))
                    put("captured_at", iso)
                }
                payload.put(row)
            }

            val url = "$supabaseUrl/rest/v1/gps_points"
            val body = payload.toString()
                .toRequestBody("application/json".toMediaType())

            val request = Request.Builder()
                .url(url)
                .post(body)
                .addHeader("apikey", supabaseKey)
                .addHeader("Authorization", "Bearer $supabaseKey")
                .addHeader("Content-Type", "application/json")
                .addHeader("Prefer", "resolution=ignore-duplicates")
                .build()

            val response = client.newCall(request).execute()
            response.use {
                if (it.isSuccessful) {
                    val count = points.length()
                    // Clear the buffer — points are now in Supabase
                    bufferPrefs.edit().putString("points", "[]").apply()
                    Log.i(TAG, "Synced $count native GPS points to Supabase")
                    count
                } else {
                    Log.w(TAG, "Supabase POST failed: ${it.code} ${it.body?.string()?.take(200)}")
                    0
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Native sync failed: ${e.message}")
            0
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsSyncer.kt
git commit -m "feat: add NativeGpsSyncer for direct Supabase POST from rescue receiver"
```

### Task 5: Integrate NativeGpsSyncer into TrackingRescueReceiver

Call the syncer after each native GPS capture, on a background thread.

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt`

- [ ] **Step 1: Add sync call after native GPS capture**

In `onReceive()`, after the `NativeGpsBuffer.save()` call (around line 228-232), add a background sync attempt:

```kotlin
// After NativeGpsBuffer.save(context, shiftId, location)
// Try to sync buffered points directly to Supabase
// (runs on a background thread to avoid blocking the receiver)
Thread {
    try {
        val synced = NativeGpsSyncer.syncBufferedPoints(context)
        if (synced > 0) {
            writeLog(context, "native_sync_$synced", shiftId)
        }
    } catch (_: Exception) {
        // Best-effort — Dart drain is the fallback
    }
}.start()
```

Place this inside the `addOnSuccessListener` block, right after `writeLog(context, "native_gps_captured", shiftId)`.

- [ ] **Step 2: Also sync on alarm fire even without new GPS capture**

At the end of `onReceive()`, just before `startAlarmChain(context)` (line 249), add a sync attempt for any previously un-synced points:

```kotlin
// Attempt to sync any buffered points even if this GPS capture failed
// (covers the case where GPS timed out but buffer has old unsent points)
Thread {
    try {
        NativeGpsSyncer.syncBufferedPoints(context)
    } catch (_: Exception) {}
}.start()
```

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt
git commit -m "feat: sync native GPS buffer to Supabase on each rescue alarm fire"
```

### Task 6: Update NativeGpsBuffer.save() to use client_id for dedup

Since native sync now POSTs directly to Supabase, and the Dart drain also inserts the same points, we need deduplication. Use a deterministic UUID based on shift_id + captured_at.

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsBuffer.kt`
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsSyncer.kt`

- [ ] **Step 1: Generate a client_id in NativeGpsBuffer.save()**

Add a `client_id` field to each saved point (deterministic UUID from shift_id + captured_at):

```kotlin
import java.util.UUID

// In save(), when building the JSONObject:
val clientId = UUID.nameUUIDFromBytes(
    "$shiftId:${location.time}".toByteArray()
).toString()
point.put("client_id", clientId)
```

- [ ] **Step 2: Include client_id in NativeGpsSyncer POST payload**

In `NativeGpsSyncer.syncBufferedPoints()`, add to the row JSONObject:

```kotlin
put("client_id", p.optString("client_id", java.util.UUID.randomUUID().toString()))
```

The `Prefer: resolution=ignore-duplicates` header already handles conflicts on the `client_id` unique constraint (if the gps_points table has one). If not, duplicate inserts with same shift_id+captured_at are harmless (the Dart drain skips already-existing points).

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsBuffer.kt gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/NativeGpsSyncer.kt
git commit -m "feat: add client_id to native GPS points for deduplication"
```

---

## Chunk 3: Device Health Telemetry on Shift Start

### Task 7: Log battery optimization + standby bucket + manufacturer at clock-in

Currently this info exists in the app but isn't logged to diagnostics at shift start. Adding it will let us proactively identify at-risk devices.

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart` (~line 518-536)

- [ ] **Step 1: Read shift_provider.dart to find the exact clock-in success block**

Read the file around lines 480-540 to see the existing diagnostic logs after successful clock-in.

- [ ] **Step 2: Add device health diagnostic log after clock-in success**

After the existing `_logger.shift(...)` call for "Clock in — tracking state at handoff", add:

```dart
// Log device health for proactive at-risk device detection
if (defaultTargetPlatform == TargetPlatform.android) {
  try {
    final batteryService = AndroidBatteryHealthService();
    final isExempt = await batteryService.isBatteryOptimizationDisabled;
    final bucketInfo = await batteryService.getAppStandbyBucket();
    final manufacturer = await batteryService.getManufacturer();
    final apiLevel = await batteryService.getApiLevel();

    _logger.battery(
      'Device health at shift start',
      shiftId: shift.serverId ?? shift.id,
      metadata: {
        'battery_optimization_exempt': isExempt,
        'standby_bucket': bucketInfo.bucketName,
        'standby_bucket_code': bucketInfo.bucket,
        'manufacturer': manufacturer,
        'api_level': apiLevel,
      },
    );
  } catch (e) {
    // Best-effort — never block clock-in for diagnostics
  }
}
```

- [ ] **Step 3: Add the import if not already present**

```dart
import 'package:gps_tracker/features/tracking/services/android_battery_health_service.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
```

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat: log battery optimization, standby bucket, and manufacturer at shift start"
```

---

## Chunk 4: Verify gps_points table supports dedup

### Task 8: Check gps_points unique constraint for client_id

**Files:**
- Check: Supabase `gps_points` table constraints

- [ ] **Step 1: Query the gps_points table constraints**

```sql
SELECT conname, contype, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'gps_points'::regclass;
```

If there's already a unique constraint on `client_id`, the `Prefer: resolution=ignore-duplicates` header in NativeGpsSyncer will handle dedup automatically.

If there's no unique constraint on `client_id`, add one via migration:

```sql
ALTER TABLE gps_points ADD CONSTRAINT gps_points_client_id_unique UNIQUE (client_id);
```

- [ ] **Step 2: Also verify the Dart drain doesn't double-insert**

Read `sync_service.dart` `_drainNativeGpsBuffers()` (lines 407-470) to confirm it uses `client_id` or similar dedup when inserting drained points into local DB.

If the Dart drain generates its own UUID for `client_id`, it will be different from the native-generated one. In that case, modify the Dart drain to use the `client_id` from the native buffer JSON (which NativeGpsBuffer.kt now includes).

- [ ] **Step 3: Commit any migration or Dart changes**

---

## Summary

| Task | What | Impact |
|------|------|--------|
| 1 | Guard FCM behind Firebase init | Fixes wake push for ALL employees |
| 2-3 | OkHttp + Supabase credentials | Enables native sync infrastructure |
| 4-6 | NativeGpsSyncer + rescue integration | GPS points sync in real-time even when Dart is dead |
| 7 | Battery/standby telemetry at shift start | Proactive identification of at-risk devices |
| 8 | Dedup constraint | Prevents duplicate GPS points from dual sync paths |
