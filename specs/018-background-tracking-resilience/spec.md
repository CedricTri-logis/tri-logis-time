# 018 - Background Tracking Resilience

## Overview

Harden the background GPS tracking system against OS-level process suspension and termination on both iOS and Android. The current implementation works well in ideal conditions but is vulnerable to: iOS suspending the app after 5-6 minutes (dual CLLocationManager conflict, no background task protection, no CLBackgroundActivitySession), and Android OEM-specific battery killers (Samsung, Xiaomi, Huawei) that bypass standard foreground service protections.

## Problem Statement

### Observed Issues
- **Jessy Mainville (2026-02-24)**: GPS tracking died after exactly 5 minutes and 30 seconds. Both GPS stream and heartbeat stopped simultaneously, indicating iOS suspended the entire process.
- **Multiple employees**: Shifts closed by `auto_zombie_cleanup` due to missing heartbeats — the app was killed silently without recovery.
- **Pattern**: ~5 GPS points collected, then complete silence. `last_heartbeat_at` stops updating at the same time as the last GPS point.

### Root Causes Identified

#### iOS
1. **Dual CLLocationManager conflict (iOS 16.4+)**: The app starts both `startUpdatingLocation()` (continuous GPS via geolocator) and `startMonitoringSignificantLocationChanges()` (cell tower via SignificantLocationPlugin) simultaneously on two separate CLLocationManager instances. Since iOS 16.4, Apple treats this as excessive/conflicting location usage and suspends the app.
2. **No `beginBackgroundTask` protection**: When the app enters background, nothing requests additional execution time from iOS. The OS can suspend immediately at its discretion.
3. **No `CLBackgroundActivitySession` (iOS 17+)**: The app doesn't use Apple's modern API for declaring legitimate continuous background activity, missing out on preferential OS treatment.
4. **`flutter_foreground_task` Timer vulnerability**: The plugin's `Timer.scheduledTimer` for repeat events (heartbeat) is paused when iOS suspends the app — it provides no protection against suspension on iOS.

#### Android
5. **No OEM-specific battery optimization handling**: The app only handles standard AOSP `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Samsung SmartManager, Xiaomi MIUI Battery Saver, Huawei App Launch Management, and similar OEM layers bypass this API and kill the foreground service anyway.
6. **Android 12+ foreground service restart fragility**: `RestartReceiver` in `flutter_foreground_task` attempts to restart the foreground service from background after being killed, which throws `ForegroundServiceStartNotAllowedException` on Android 12+ without battery optimization exemption.
7. **No thermal state monitoring**: Neither platform adapts GPS behavior when the device overheats, making the app a prime target for thermal throttling kills.

## Solution Design

### iOS Improvements

#### iOS-1: Deferred SignificantLocationChanges Activation
**Current**: `SignificantLocationService.startMonitoring()` is called immediately on `TrackingSuccess` in `startTracking()`, creating a second `CLLocationManager` alongside the geolocator stream.

**New**: Start only the continuous GPS stream at clock-in. Activate `SignificantLocationChanges` only as a fallback when the GPS stream dies (detected by existing `_checkStreamHealth` in `GPSTrackingHandler` after 90s with no position). Stop `SignificantLocationChanges` when the stream recovers.

**Files**: `tracking_provider.dart`, `significant_location_service.dart`, `gps_tracking_handler.dart`

#### iOS-2: beginBackgroundTask Protection
**Current**: No special handling when the app transitions to background.

**New**: Add a native Swift method in `AppDelegate` that calls `UIApplication.shared.beginBackgroundTask(expirationHandler:)` when the app enters background during an active shift. This requests ~30 seconds of additional execution time from iOS before suspension. End the task when the expiration handler fires or the app returns to foreground.

**Files**: `AppDelegate.swift` (new method), `background_tracking_service.dart` (method channel call on lifecycle change)

#### iOS-3: CLBackgroundActivitySession (iOS 17+)
**Current**: Relies solely on `allowsBackgroundLocationUpdates = true` (legacy API).

**New**: On iOS 17+, create a `CLBackgroundActivitySession` when tracking starts and invalidate it when tracking stops. This explicitly tells iOS the app has a legitimate need for continuous background execution, granting preferential treatment (less likely to be suspended). On iOS < 17, fall back to current behavior.

**Files**: `SignificantLocationPlugin.swift` (add session management methods), `background_tracking_service.dart` (call via method channel)

### Android Improvements

#### Android-1: OEM-Specific Battery Optimization Guidance
**Current**: `BatteryOptimizationDialog` shows a generic dialog about disabling battery optimization. Only handles the AOSP API.

**New**: Detect the device manufacturer via a method channel (`Build.MANUFACTURER`). Show manufacturer-specific instructions with deep links to the correct OEM settings screen:
- **Samsung**: Settings > Battery > Background usage limits > Never sleeping apps
- **Xiaomi**: Settings > Apps > Manage apps > [app] > Autostart: On + Battery saver: No restrictions
- **Huawei**: Settings > Battery > App launch > Manage manually (enable all 3 toggles)
- **OnePlus/Oppo**: Settings > Battery > Battery optimization > Don't optimize + Allow background activity
- **Other OEMs**: Show generic guidance with link to dontkillmyapp.com

Persist a `oem_setup_completed` flag in SharedPreferences to avoid re-showing. Show at first clock-in and when GPS tracking dies unexpectedly.

**Files**: New `oem_battery_guide_dialog.dart`, new `device_info_service.dart` (method channel), `battery_optimization_dialog.dart` (update to delegate to OEM dialog), `tracking_provider.dart` (trigger on tracking failure)

#### Android-2: Foreground Service Restart Hardening (Android 12+)
**Current**: `RestartReceiver` in flutter_foreground_task attempts to restart the foreground service from background, which can throw `ForegroundServiceStartNotAllowedException` on Android 12+.

**New**: Add `SCHEDULE_EXACT_ALARM` permission to manifest for reliable restart timing. In the app layer, add a check on `FlutterForegroundTask.isRunningService` when the app returns to foreground — if the service died during an active shift, show a notification explaining what happened and auto-restart the service (since we're now in foreground context, this is allowed on Android 12+).

**Files**: `AndroidManifest.xml`, `tracking_provider.dart` (add foreground resume check), `notification_service.dart` (service death notification)

### Cross-Platform Improvements

#### Cross-1: Thermal State Monitoring
**Current**: No thermal monitoring on either platform.

**New**: Add a cross-platform `ThermalStateService` that monitors device thermal state:
- **iOS**: `ProcessInfo.processInfo.thermalState` via method channel
- **Android**: `PowerManager.getCurrentThermalStatus()` via method channel (API 29+)

Behavior adaptation:
| Thermal Level | Action |
|---|---|
| Normal/Fair/Light | `LocationAccuracy.high`, 60s interval (current behavior) |
| Serious/Moderate | `LocationAccuracy.medium`, 120s interval |
| Critical/Severe+ | `LocationAccuracy.low`, 300s interval, log event |

Send config update to background handler via existing `updateConfig` command.

**Files**: New `thermal_state_service.dart`, new native Swift/Kotlin method channel handlers, `tracking_provider.dart` (listen to thermal changes), `gps_tracking_handler.dart` (already supports dynamic config updates)

## Files to Create
- `gps_tracker/lib/features/tracking/services/thermal_state_service.dart` — Cross-platform thermal monitoring
- `gps_tracker/lib/features/tracking/services/device_info_service.dart` — Device manufacturer detection (Android)
- `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart` — OEM-specific setup instructions
- `gps_tracker/ios/Runner/BackgroundTaskPlugin.swift` — Native iOS plugin for beginBackgroundTask + CLBackgroundActivitySession

## Files to Modify
- `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — Deferred SignificantLocation, thermal adaptation, foreground resume check
- `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart` — Notify main isolate when stream dies (for SignificantLocation activation)
- `gps_tracker/lib/features/tracking/services/significant_location_service.dart` — Add start/stop from background handler signal
- `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` — Lifecycle hooks for beginBackgroundTask
- `gps_tracker/ios/Runner/SignificantLocationPlugin.swift` — Add CLBackgroundActivitySession management
- `gps_tracker/ios/Runner/AppDelegate.swift` — Register new plugin
- `gps_tracker/android/app/src/main/AndroidManifest.xml` — SCHEDULE_EXACT_ALARM permission
- `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart` — Delegate to OEM guide

## Non-Goals
- Changing the GPS polling interval (distanceFilter: 0 is correct and must stay)
- Replacing flutter_foreground_task or geolocator plugins
- Adding server-side GPS gap detection (already exists via zombie cleanup)
- Handling the "user manually killed the app" scenario (SignificantLocationChanges already covers this)

## Testing Strategy
- Test iOS tracking survival beyond 10 minutes on real device (not simulator)
- Test on Samsung, Xiaomi devices if available (OEM killer validation)
- Verify SignificantLocationChanges only activates after stream death, not at clock-in
- Verify CLBackgroundActivitySession is created on iOS 17+ and falls back gracefully on iOS 16
- Verify thermal adaptation by simulating thermal states via Xcode debug tools
- Monitor `auto_zombie_cleanup` rate before/after deployment as success metric
