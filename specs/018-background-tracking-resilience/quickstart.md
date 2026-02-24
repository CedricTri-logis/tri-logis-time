# Quickstart: 018 - Background Tracking Resilience

## Prerequisites

- Flutter >=3.29.0 with iOS and Android targets configured
- Xcode 15+ (for iOS 17 CLBackgroundActivitySession API)
- Physical iOS device for background testing (simulator does not accurately simulate suspension)
- Samsung/Xiaomi/Huawei device (if available) for OEM battery killer testing

## Implementation Order

The feature has 6 independent improvements that can be implemented in any order, but the recommended sequence minimizes dependencies:

### Phase 1: iOS Core Fixes (Highest Impact)

**1. iOS-1: Deferred SignificantLocationChanges**
- Modify `tracking_provider.dart`: Remove `SignificantLocationService.startMonitoring()` from `startTracking()`
- Wire `gps_lost` signal → `startMonitoring()`, `gps_restored` signal → `stopMonitoring()`
- Test: Clock in → verify SLC is NOT active → wait for stream death → verify SLC activates

**2. iOS-2 + iOS-3: BackgroundTaskPlugin (beginBackgroundTask + CLBackgroundActivitySession)**
- Create `BackgroundTaskPlugin.swift` with both APIs
- Register in `AppDelegate.swift`
- Create `BackgroundExecutionService` Dart wrapper (no-op on Android)
- Wire into `tracking_provider.dart` (startTracking/stopTracking) and `background_tracking_service.dart` (lifecycle)
- Test: Clock in → background app → verify tracking survives >10 minutes

### Phase 2: Android Hardening

**3. Android-1: OEM Battery Guide**
- Create `oem_battery_guide_dialog.dart` with French instructions per OEM
- Add `openOemBatterySettings` method channel in `MainActivity.kt`
- Modify `battery_optimization_dialog.dart` to chain to OEM guide
- Test: On Samsung device, verify deep link opens correct settings screen

**4. Android-2: Foreground Service Resume Check**
- Add `FlutterForegroundTask.isRunningService` check in `tracking_provider.dart` when app resumes
- If service died during active shift → auto-restart
- Test: Force-kill foreground service → reopen app → verify tracking restarts

### Phase 3: Cross-Platform Enhancement

**5. Cross-1: Thermal State Monitoring**
- Create `thermal_state_service.dart` (Dart)
- Add thermal method channel to `BackgroundTaskPlugin.swift` (iOS) and `MainActivity.kt` (Android)
- Wire thermal level changes to `updateConfig` in `tracking_provider.dart`
- Test: Use Xcode Thermal State simulation to verify GPS interval adaptation

## Key Files Quick Reference

| File | Action | Purpose |
|------|--------|---------|
| `lib/features/tracking/providers/tracking_provider.dart` | MODIFY | Deferred SLC, thermal adaptation, FGS resume check |
| `lib/features/tracking/services/background_tracking_service.dart` | MODIFY | beginBackgroundTask lifecycle hooks |
| `lib/features/tracking/services/gps_tracking_handler.dart` | MODIFY | Ensure gps_lost/gps_restored signals are reliable |
| `lib/features/tracking/services/significant_location_service.dart` | MODIFY | No functional change (start/stop already exist) |
| `lib/features/tracking/services/thermal_state_service.dart` | NEW | Cross-platform thermal monitoring |
| `lib/features/tracking/widgets/oem_battery_guide_dialog.dart` | NEW | OEM-specific battery setup instructions |
| `lib/features/tracking/widgets/battery_optimization_dialog.dart` | MODIFY | Chain to OEM guide after AOSP dialog |
| `ios/Runner/BackgroundTaskPlugin.swift` | NEW | beginBackgroundTask + CLBackgroundActivitySession |
| `ios/Runner/SignificantLocationPlugin.swift` | NO CHANGE | Existing SLC plugin (no modifications needed) |
| `ios/Runner/AppDelegate.swift` | MODIFY | Register BackgroundTaskPlugin |
| `android/app/src/main/kotlin/.../MainActivity.kt` | MODIFY | Thermal + OEM method channels |

## Testing Checklist

- [ ] iOS: Tracking survives >10 minutes in background (real device, not simulator)
- [ ] iOS: SLC does NOT activate at clock-in (only after stream death)
- [ ] iOS: CLBackgroundActivitySession created on iOS 17+, no crash on iOS 16
- [ ] iOS: beginBackgroundTask protects the background transition moment
- [ ] Android: OEM guide shows for Samsung/Xiaomi/Huawei
- [ ] Android: Deep link opens correct OEM settings screen
- [ ] Android: `oem_setup_completed` persists across app restarts
- [ ] Android: Foreground service resumes after being killed (app returns to foreground)
- [ ] Cross: Thermal adaptation changes GPS interval (Xcode thermal simulation)
- [ ] Cross: `auto_zombie_cleanup` rate decreases after deployment
- [ ] Regression: Clock-in/out flow unchanged
- [ ] Regression: GPS points still captured at expected intervals
- [ ] Regression: SLC still relaunches app after true termination
