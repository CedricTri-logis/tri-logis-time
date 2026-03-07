# Telemetry Expansion Design (Feature 020)

Date: 2026-03-07
Status: Approved
Problem: Crashes and GPS gaps occur with no visibility into root cause. Current DiagnosticLogger covers Dart-level events but misses native platform data (iOS location pauses, Android doze mode, GNSS satellite status, memory pressure, battery depletion).

## Goals

1. Capture 100% of crashes (Dart + native) with symbolicated stacks
2. Know exactly WHY GPS tracking stopped (battery, doze, location pause, memory kill, permission revoke)
3. Correlate battery level with GPS gaps
4. Zero impact on app performance or stability

## Decisions

- **Crash reporting:** Firebase Crashlytics (free, unlimited, Firebase already in project)
- **Custom telemetry:** DiagnosticLogger + Supabase (existing pipeline, expanded categories)
- **Implementation:** 3 incremental phases, each independently deployable
- **Log structure:** Keep existing table separation (gps_points, gps_gaps, diagnostic_logs, device_status). Expand diagnostic_logs categories only. No table consolidation.

## Architecture

```
Phone (Dart + Native)
  |
  +-- Crashes -----------------> Firebase Crashlytics (symbolication)
  |                              + DiagnosticLogger (double-write)
  |
  +-- GPS telemetry -----------> DiagnosticLogger
  |   (pause/resume, GNSS,        -> SQLCipher local (5K max)
  |    battery, doze, memory)        -> sync_diagnostic_logs RPC
  |                                    -> diagnostic_logs table (90 days)
  |
  +-- GPS points --------------> gps_points table (+ battery_level column)
```

## Phase 1 -- Quick Wins (Dart-Only)

No native code. Deployable in a single build.

### 1.1 Firebase Crashlytics

- Add `firebase_crashlytics` to pubspec.yaml
- In main.dart: `FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError`
- In main.dart: `PlatformDispatcher.instance.onError` -> forward to Crashlytics
- Wrap `runApp()` in `runZonedGuarded` -> forward uncaught async errors to Crashlytics
- Double-write: also log to DiagnosticLogger category `crash` for Supabase visibility
- Fastlane: add dSYM upload step (iOS) and ProGuard mapping upload (Android)

### 1.2 Battery Level on GPS Points

- Add `battery_plus` package
- Read battery % in GPS tracking handler alongside each position capture
- Include `battery_level` (0-100) in GPS point data sent to sync
- Migration: `ALTER TABLE gps_points ADD COLUMN battery_level SMALLINT`
- Update `sync_gps_points` RPC to accept and store `battery_level`

### 1.3 Unhandled Exception Handler

```dart
// main.dart
runZonedGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ... existing init ...

  FlutterError.onError = (details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    // Double-write to DiagnosticLogger
    if (DiagnosticLogger.isInitialized) {
      DiagnosticLogger.instance.log(
        category: EventCategory.crash,
        severity: Severity.critical,
        message: 'Flutter error: ${details.exceptionAsString()}',
        metadata: {'stack': details.stack?.toString().substring(0, 500)},
      );
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  runApp(const ProviderScope(child: GpsTrackerApp()));
}, (error, stack) {
  FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
});
```

### 1.4 Expanded Diagnostic Categories

Migration adds categories to the CHECK constraint:

```sql
ALTER TABLE diagnostic_logs
  DROP CONSTRAINT diagnostic_logs_event_category_check,
  ADD CONSTRAINT diagnostic_logs_event_category_check
    CHECK (event_category IN (
      'gps', 'shift', 'sync', 'auth', 'permission',
      'lifecycle', 'thermal', 'error', 'network',
      -- New categories
      'battery', 'memory', 'crash', 'service',
      'satellite', 'doze', 'motion', 'metrickit'
    ));
```

Dart enum `EventCategory` updated to match.

### 1.5 App Lifecycle Logging

Enhance existing `WidgetsBindingObserver` to log all state changes:

- `app_paused` (info) -- app entered background
- `app_resumed` (info) -- app returned to foreground
- `app_detached` (warn) -- app being terminated
- `app_inactive` (debug) -- app temporarily inactive (call, notification)

These go to DiagnosticLogger category `lifecycle`.

### Phase 1 Deliverables

- 1 Supabase migration (battery_level column + expanded categories)
- 1 new package (`firebase_crashlytics`, `battery_plus`)
- Modified files: main.dart, diagnostic_event.dart, diagnostic_logger.dart, gps_tracking_handler.dart, sync_gps_points RPC
- Fastlane: dSYM upload step

## Phase 2 -- iOS Native Platform Channel (Swift)

Single Swift plugin file in `ios/Runner/` with MethodChannel + EventChannel.

### 2.1 MetricKit Subscriber

- Register `MXMetricManagerSubscriber` in AppDelegate
- On `didReceive(_: [MXDiagnosticPayload])`: extract crash diagnostics, hang diagnostics, app exit reasons
- Serialize to JSON, send to Dart via EventChannel
- Dart side: log to DiagnosticLogger category `metrickit`
- Key data: `MXCrashDiagnostic` (crash stacks), `MXAppExitMetric` (why app was killed), `MXLocationActivityMetric` (GPS time consumed)

### 2.2 Location Pause/Resume Detection

- Custom CLLocationManagerDelegate wrapper (or swizzle geolocator's delegate)
- Intercept `locationManagerDidPauseLocationUpdates` and `locationManagerDidResumeLocationUpdates`
- Send to Dart via EventChannel
- Dart side: log to DiagnosticLogger category `gps`, severity `warn`
- This is the #1 cause of iOS GPS gaps

### 2.3 Memory Pressure Source

- `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`
- On pressure event: send level to Dart via EventChannel
- Dart side: log to DiagnosticLogger category `memory`
- Works in background

### Phase 2 Deliverables

- 1 Swift file: `DiagnosticNativePlugin.swift` (~150 lines)
- 1 Dart file: `diagnostic_native_ios.dart` (EventChannel listener)
- Modified: AppDelegate.swift (register plugin)

## Phase 3 -- Android Native Platform Channel (Kotlin)

Single Kotlin plugin file with MethodChannel + EventChannel.

### 3.1 GNSS Satellite Status

- `LocationManager.registerGnssStatusCallback(GnssStatus.Callback)`
- On status change: satellite count, avg CN0 (signal strength), TTFF
- Send to Dart via EventChannel
- Dart side: log to DiagnosticLogger category `satellite`
- Throttle: log only every 60s or on significant change (satellites < 4)

### 3.2 Doze Mode Detection

- Register `BroadcastReceiver` for `ACTION_DEVICE_IDLE_MODE_CHANGED`
- Check `PowerManager.isDeviceIdleMode()`
- On change: send doze state to Dart via EventChannel
- Dart side: log to DiagnosticLogger category `doze`

### 3.3 Continuous Standby Bucket Monitoring

- `UsageStatsManager.getAppStandbyBucket()` checked every 5 minutes during active shift
- Log changes only (ACTIVE -> WORKING_SET -> FREQUENT -> RARE -> RESTRICTED)
- Dart side: log to DiagnosticLogger category `service`
- Currently only checked at clock-in via device_status; this adds continuous monitoring

### 3.4 Foreground Service Death Detection

- Override `onTaskRemoved()` and `onDestroy()` in the foreground service
- Log to DiagnosticLogger category `service` severity `error`
- Best-effort: if process is killed by OOM, this callback may not fire (Crashlytics covers that case)

### Phase 3 Deliverables

- 1 Kotlin file: `DiagnosticNativePlugin.kt` (~200 lines)
- 1 Dart file: `diagnostic_native_android.dart` (EventChannel listener)
- Modified: MainActivity.kt (register plugin)

## Safety Guarantees

All new code follows the existing fire-and-forget pattern:

1. **Every platform channel call** wrapped in `try/catch` Dart-side that silently ignores failures
2. **Every native callback** wrapped in try/catch on the native side
3. **No business logic depends on telemetry** -- if any part fails, GPS tracking and shifts work identically
4. **Crashlytics SDK** is designed to never crash the host app (used by millions of apps)
5. **Battery reads** are cached per GPS point cycle -- no extra wake-ups or battery drain
6. **Local storage cap** unchanged at 5000 events with automatic pruning
7. **Sync priority** unchanged -- diagnostic events sync last, after GPS points and shifts

## What Does NOT Change

- DiagnosticLogger architecture (singleton, fire-and-forget, 5 layers of try/catch)
- Existing tables (gps_gaps, shifts, device_status structure)
- Sync pipeline priority order (shifts > gps_gaps > gps_points > trips > lunch_breaks > diagnostics)
- GPS Health Guard (complementary -- it detects/fixes, telemetry explains why)
- Local event cap (5000) and pruning strategy
- Server retention (90 days diagnostic_logs)

## Relation to GPS Health Guard

GPS Health Guard detects that the foreground service is dead and restarts it. The telemetry expansion explains WHY it died:

```
GPS Health Guard log:  "service dead, restarting"  (source: cleaning_scan_in)
Telemetry log:         "doze_mode_entered" 2 min before
Telemetry log:         "battery_level: 3%" at last GPS point
Telemetry log:         "memory_pressure: critical" 30s before
```

Together they provide both the detection/recovery AND the root cause diagnosis.

## New Diagnostic Event Categories

| Category | Events | Phase |
|----------|--------|-------|
| `crash` | Dart uncaught exception, platform error | 1 |
| `battery` | Battery level changes, low battery warnings | 1 |
| `memory` | Memory pressure warning/critical | 2 (iOS) / 3 (Android) |
| `service` | Foreground service death, standby bucket change | 3 |
| `satellite` | GNSS satellite count, signal strength, TTFF | 3 |
| `doze` | Doze mode enter/exit | 3 |
| `metrickit` | iOS crash diagnostic, hang diagnostic, app exit metric | 2 |
| `motion` | Reserved for future CoreMotion/ActivityRecognition | Future |
