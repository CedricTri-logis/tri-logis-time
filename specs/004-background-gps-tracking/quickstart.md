# Quickstart: Background GPS Tracking Development

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08

---

## Prerequisites

- Flutter SDK 3.x (stable)
- Xcode 15+ (for iOS development)
- Android Studio / Android SDK API 24+
- Physical device recommended for background testing (simulator has limitations)

---

## Setup Steps

### 1. Verify Dependencies

The required dependencies are already in `pubspec.yaml`:

```yaml
dependencies:
  flutter_foreground_task: ^8.0.0
  geolocator: ^12.0.0
  disable_battery_optimization: ^1.1.1
  flutter_map: ^6.0.0  # Add this for route visualization
  latlong2: ^0.9.0     # Add this for map coordinates
```

Run:
```bash
cd gps_tracker
flutter pub get
```

### 2. Verify Android Configuration

Check `android/app/src/main/AndroidManifest.xml` has:

```xml
<!-- Permissions (should already exist) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

<!-- Service declaration (ADD if not present) -->
<application ...>
    <service
        android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
        android:foregroundServiceType="location"
        android:stopWithTask="false"
        android:exported="false" />
</application>
```

### 3. Verify iOS Configuration

Check `ios/Runner/Info.plist` has:

```xml
<!-- Location permissions (should already exist) -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location access is required to record your position when you clock in and out.</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Background location access is required to track your work route during active shifts. Your location is only tracked while you are clocked in.</string>

<!-- Background modes (should already exist) -->
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
</array>

<!-- BGTaskScheduler (ADD if not present) -->
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.pravera.flutter_foreground_task.refresh</string>
</array>
```

### 4. Update iOS AppDelegate

Edit `ios/Runner/AppDelegate.swift`:

```swift
import UIKit
import Flutter
import flutter_foreground_task

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Required for flutter_foreground_task
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

---

## Development Workflow

### Create Feature Directory Structure

```bash
mkdir -p gps_tracker/lib/features/tracking/{models,providers,services,screens,widgets}
mkdir -p gps_tracker/test/features/tracking/{providers,services}
```

### Implementation Order

1. **Models** (no dependencies)
   - `tracking_config.dart`
   - `tracking_status.dart`
   - `tracking_state.dart`
   - `location_permission_state.dart`
   - `route_point.dart`

2. **Services** (depends on models)
   - `background_tracking_service.dart`

3. **Providers** (depends on services)
   - `tracking_provider.dart`
   - `route_provider.dart`

4. **Widgets** (depends on providers)
   - `tracking_status_indicator.dart`
   - `gps_point_marker.dart`
   - `route_map_widget.dart`
   - `point_detail_sheet.dart`
   - `route_stats_card.dart`

5. **Integration** (modify existing files)
   - Update `main.dart` for service initialization
   - Update `shift_provider.dart` for tracking integration
   - Update `shift_status_card.dart` for status indicator
   - Update `shift_detail_screen.dart` for route map

---

## Running the App

### iOS Simulator
```bash
flutter run -d ios
```
Note: Background location has limitations in simulator. Test on physical device.

### Android Emulator
```bash
flutter run -d android
```
Enable location services in emulator settings.

### Physical Device (Recommended)
```bash
flutter run -d <device-id>
```
Get device ID with `flutter devices`.

---

## Testing Background Tracking

### Manual Test Flow

1. **Grant Permissions**
   - Launch app
   - Clock in (triggers permission request)
   - Grant "Always" location permission

2. **Verify Tracking Starts**
   - Confirm notification appears (Android)
   - Confirm tracking indicator shows "Tracking Active"

3. **Test Background Behavior**
   - Lock phone or switch to another app
   - Move to different location
   - Wait for tracking interval (5 minutes default)
   - Return to app and verify point was captured

4. **Test Offline Storage**
   - Enable airplane mode
   - Move to different locations
   - Disable airplane mode
   - Verify points sync

5. **Test Clock Out**
   - Clock out
   - Verify notification disappears
   - Verify tracking indicator shows "Stopped"

6. **Test Route Display**
   - View completed shift
   - Verify map shows tracked route
   - Tap points to see timestamps

### Automated Tests

```bash
# Unit tests
flutter test test/features/tracking/

# Integration tests (requires emulator/device)
flutter test integration_test/background_tracking_integration_test.dart
```

---

## Debugging Tips

### View Background Logs (Android)
```bash
adb logcat | grep -E "(flutter|ForegroundService|LocationService)"
```

### View Background Logs (iOS)
Use Xcode Console when device is connected.

### Check Service Status
```dart
final isRunning = await FlutterForegroundTask.isRunningService;
print('Background service running: $isRunning');
```

### Force Sync
```dart
ref.read(syncProvider.notifier).syncPendingData();
```

### Clear Local Data (Development Only)
```dart
await LocalDatabase.instance.clearAllData();
```

---

## Common Issues

### Issue: Service not starting on Android
**Cause**: Missing foreground service declaration
**Fix**: Add `<service>` element to AndroidManifest.xml

### Issue: No location updates in iOS background
**Cause**: Missing "Always" permission
**Fix**: Guide user to enable in Settings > Privacy > Location Services

### Issue: Service killed by battery optimization
**Cause**: OEM-specific battery saving
**Fix**: Request battery optimization exemption + guide user

### Issue: Points not syncing
**Cause**: Network connectivity or auth issues
**Fix**: Check `SyncProvider` state, verify Supabase connection

---

## Environment Variables

Ensure `.env` file exists with Supabase credentials:

```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

---

## Useful Commands

```bash
# Analyze code
flutter analyze

# Run all tests
flutter test

# Build debug APK
flutter build apk --debug

# Build debug iOS
flutter build ios --debug

# Check Supabase status
cd supabase && supabase status
```
