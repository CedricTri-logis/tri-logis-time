# Post-Kill Diagnostic Enrichment

**Date:** 2026-03-16
**Goal:** Better understand why Android kills the GPS tracking service during active shifts by enriching diagnostic logging at restart and health check points.

## Context

GPS gaps of 1-2 hours occur on Samsung Android devices during active shifts. The app's foreground service gets killed despite battery optimization exemption. Current logging captures the standby bucket at shift start and bucket changes via 5-min polling, but provides no forensic data about WHY the process was killed or what the device state was at restart.

## Changes

### 1. Cold Start with Active Shift — Exit Reason Collection

**Native (Kotlin - MainActivity.kt):**
- New MethodChannel handler `getProcessExitReasons`
- Uses `ActivityManager.getHistoricalProcessExitReasons()` (API 30+, Android 11+)
- Returns list of recent exit reasons: `reason` (int), `description` (string), `importance` (int), `timestamp` (long), `pss`/`rss` (memory stats)
- Falls back gracefully on API < 30 (returns empty list)

**Dart (shift reconciliation path):**
- When app cold-starts and finds an active shift, log a diagnostic event:
  - Category: `lifecycle`
  - Severity: `warn`
  - Message: `"Post-kill restart diagnostic"`
  - Metadata:
    - `exit_reasons`: array from native (last 3 reasons)
    - `standby_bucket`: current bucket name
    - `standby_bucket_code`: current bucket int
    - `gap_duration_seconds`: seconds since last local GPS point
    - `foreground_service_was_alive`: bool
    - `battery_level`: current level
    - `shift_id`: active shift ID

### 2. GpsHealthGuard — Bucket in Dead-Service Metadata

**File:** `gps_health_guard.dart`
- In `ensureAlive()` and `nudge()`, when `service_was_alive == false`:
  - Fetch current standby bucket via `AndroidBatteryHealthService.getAppStandbyBucket()`
  - Add `standby_bucket` and `standby_bucket_code` to existing log metadata

### 3. TrackingWatchdogService — Bucket in Breadcrumbs

**File:** `tracking_watchdog_service.dart`
- In `_checkAndRestart()`, fetch standby bucket
- Include bucket name in the breadcrumb string format: `timestamp|source|outcome|shift_id|bucket`
- When breadcrumbs are synced to diagnostic logs on app resume, the bucket info is preserved

## Not Changed

- Native 5-min bucket polling (already exists in DiagnosticNativePlugin.kt)
- Shift-start device health log (already exists)
- No new Supabase tables or migrations
- No new UI elements
- No new dependencies
