# Background Tracking Resilience v2 — Design

> Date: 2026-03-03 | Status: Approved

## Problem Statement

Analysis of today's production logs shows **43% of active shifts** (6/14) have their app killed by the OS, resulting in GPS data loss. Current resilience mechanisms (rescue alarm, SLC, exponential backoff) detect the kills and attempt recovery, but:

1. **Database contention**: 1,351 errors/day from concurrent `detect_trips`/`detect_carpools` calls (deadlocks + statement timeouts)
2. **Rescue alarm restarts Flutter but not GPS**: The service process restarts but the geolocator stream inside doesn't recover
3. **No server-initiated wake**: The server knows heartbeats are stale but can't do anything about it
4. **No user notification**: Employees don't know their shift isn't being tracked

## Approach: "Layer by Layer" (3 Phases)

Each phase is independently deployable and immediately improves the situation.

---

## Phase 1: DB Quick Wins

### 1.1 Advisory Locks on detect_trips

Add `pg_advisory_xact_lock(hashtext(p_shift_id::text))` at the start of `detect_trips`. The lock is automatically released at transaction end. A second concurrent call for the same shift waits instead of deadlocking.

Same for `detect_carpools`:
```sql
PERFORM pg_advisory_xact_lock(hashtext('carpools_' || p_date::text));
```

**Impact**: Eliminates 1,351 deadlock/timeout errors per day.

### 1.2 Skip detect_trips During Active Shifts

Remove the `detect_trips` call on the active shift from `sync_provider.dart`. Only call it:
- At clock-out (shift completed)
- On the 10 most recent completed shifts (already existing)

**Why it's safe**: detect_trips is idempotent and results aren't visible to employees during their shift. Trips/clusters are only used for supervisor approvals, which happen after the shift.

### 1.3 Reduce Stationary Interval from 120s to 60s

Change `_stationaryIntervalSeconds` from 120 to 60 in `gps_tracking_handler.dart`.

**Why**: With 120s intervals, a "normal" gap in stationary mode is 120s. We can't distinguish "normal" from "dead" before 240s+. With 60s, we detect death in 120s.

**Battery impact**: Negligible. On iOS, `distanceFilter: 0` means the GPS chip already fires continuously — we filter in software. On Android, the `androidInterval: 15s` hint is already set.

---

## Phase 2: Native Client Resilience

### 2.1 Native GPS Capture — Android (Rescue Alarm)

When `TrackingRescueReceiver` fires every 45s and detects the Flutter service is dead, it captures a GPS point directly in Kotlin via `FusedLocationProviderClient`:

```kotlin
val fusedClient = LocationServices.getFusedLocationProviderClient(context)
fusedClient.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cancellationToken)
  .addOnSuccessListener { location ->
    saveNativeGpsPoint(context, shiftId, location)
  }
```

**Buffer**: GPS points stored as JSON in SharedPreferences (max 100 points). On next Flutter resume, `sync_provider` reads these points via MethodChannel and inserts into SQLCipher → syncs to Supabase.

**Dependency**: `com.google.android.gms:play-services-location` (already available via geolocator).

### 2.2 Native GPS Capture — iOS (SLC Callback)

When `SignificantLocationPlugin.didUpdateLocations()` fires, in addition to notifying Flutter via MethodChannel, save the GPS point in `UserDefaults` as a buffer.

**Why**: If the Flutter engine is dead (the case we want to cover), the MethodChannel call fails silently. By saving natively, we don't lose the point.

**Buffer**: `UserDefaults` with a JSON array of points (max 100). Flutter reads on resume.

### 2.3 "Shift Not Tracked" Alert Notification

If no GPS point is captured for > 5 minutes during an active shift, show a separate notification:
- **Title**: "Suivi de position interrompu"
- **Body**: "Votre quart n'est plus suivi. Appuyez pour reprendre."
- **Action**: Open app (which automatically relaunches tracking)

**Trigger**: In the background handler heartbeat loop (every 30s), check time since last GPS capture. If > 5 min → local notification via `flutter_local_notifications`.

**Cancellation**: As soon as a GPS point is captured, the notification is automatically dismissed.

**Implementation**: Separate notification (different ID) from the foreground service notification. Simpler and more reliable.

---

## Phase 3: Firebase Silent Push

### 3.1 Firebase Setup

1. Create Firebase project (or link existing) via Firebase Console
2. Add Android + iOS apps
3. Download `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
4. Add `firebase_core` + `firebase_messaging` to pubspec.yaml
5. Initialize Firebase in `main.dart`
6. Save FCM token in `employee_profiles` (new column `fcm_token`) at login and on token refresh

### 3.2 Edge Function "send-wake-push"

Supabase Edge Function that sends a silent push to a device via FCM HTTP v1 API.

**Silent message format**:
- iOS: `content-available: 1` + no `alert/sound/badge` → wakes app in background for ~30s
- Android: `data` message without `notification` → wakes service in background

Firebase service account key stored as Supabase secret (`FIREBASE_SERVICE_ACCOUNT_KEY`).

### 3.3 pg_cron Job "wake_stale_devices"

Job running every 2 minutes. Detects active shifts with stale heartbeats (> 5 min) and calls the Edge Function.

```sql
SELECT employee_id, fcm_token
FROM shifts s
JOIN employee_profiles ep ON ep.id = s.employee_id
WHERE s.status = 'active'
  AND s.last_heartbeat_at < now() - interval '5 minutes'
  AND ep.fcm_token IS NOT NULL
  AND (ep.last_wake_push_at IS NULL
       OR ep.last_wake_push_at < now() - interval '5 minutes');
```

**Throttling**: `last_wake_push_at` column on `employee_profiles` — max 1 push per 5 minutes per employee.

### 3.4 Client-Side Reception

When the app receives the silent push:
1. `firebase_messaging` background handler fires
2. Check if there's an active shift (SharedPreferences)
3. If yes + foreground service dead → restart tracking
4. Send heartbeat to server to confirm wake

**iOS advantage**: Silent push via APNs is more reliable than SLC for waking stationary devices (no 500m movement needed).

**Android advantage**: Data-only FCM high-priority message can start a foreground service from background on Android 12+ (FCM exemption).

---

## Summary of Expected Impact

| Metric | Before | After Phase 1 | After Phase 2 | After Phase 3 |
|--------|--------|---------------|---------------|---------------|
| DB errors/day | 1,351 | ~0 | ~0 | ~0 |
| Apps killed unrecovered | 43% | 43% | ~20% (native capture fills gaps) | ~5% (push wakes dead apps) |
| Time to detect death | 240s+ | 120s | 120s + user notified at 5min | 120s + auto-wake at 5min |
| GPS points lost per kill | All until manual resume | All until manual resume | 1 per 45s (native buffer) | Near-zero (push + native) |

## Files to Modify

### Phase 1
- `supabase/migrations/125_advisory_locks_detect_trips.sql` — advisory locks
- `gps_tracker/lib/features/shifts/providers/sync_provider.dart` — skip active detect_trips
- `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart` — stationary interval 60s

### Phase 2
- `gps_tracker/android/.../TrackingRescueReceiver.kt` — native GPS capture
- `gps_tracker/android/.../MainActivity.kt` — MethodChannel for reading native buffer
- `gps_tracker/ios/Runner/SignificantLocationPlugin.swift` — native GPS buffer
- `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart` — alert notification
- `gps_tracker/lib/features/shifts/providers/sync_provider.dart` — read native GPS buffers

### Phase 3
- `gps_tracker/pubspec.yaml` — firebase_core, firebase_messaging
- `gps_tracker/android/app/google-services.json` — Firebase config
- `gps_tracker/ios/Runner/GoogleService-Info.plist` — Firebase config
- `gps_tracker/lib/main.dart` — Firebase init
- `gps_tracker/lib/features/auth/` — save FCM token
- `supabase/migrations/126_fcm_token_and_wake_push.sql` — fcm_token column + last_wake_push_at
- `supabase/functions/send-wake-push/index.ts` — Edge Function
- `supabase/migrations/127_wake_stale_devices_cron.sql` — pg_cron job
