# Quickstart: Location Permission Guard

**Feature**: 007-location-permission-guard
**Date**: 2026-01-10

## Overview

This guide provides a quick reference for implementing the Location Permission Guard feature. Follow these steps to add proactive permission status display, guided request flows, pre-shift checking, and real-time monitoring.

---

## Prerequisites

- Specs 001-006 implemented (foundation, auth, shifts, tracking, offline, history)
- Flutter 3.0+ with existing dependencies:
  - `geolocator: ^12.0.0`
  - `flutter_riverpod: ^2.5.0`
  - `flutter_foreground_task: ^8.0.0`

---

## Implementation Order

### Phase 1: Core State & Models

1. **Create `DeviceLocationStatus` enum** (`models/device_location_status.dart`)
2. **Create `PermissionGuardStatus` enum** (`models/permission_guard_status.dart`)
3. **Create `PermissionGuardState` model** (`models/permission_guard_state.dart`)
4. **Create `PermissionChangeEvent` model** (`models/permission_change_event.dart`)

### Phase 2: Provider Layer

5. **Create `PermissionGuardNotifier`** (`providers/permission_guard_provider.dart`)
   - Implements `checkStatus()`, `dismissWarning()`, `setActiveShift()`
   - Integrates with existing `BackgroundTrackingService` for permission checks
6. **Create derived providers** (same file)
   - `permissionGuardStatusProvider`
   - `shouldShowPermissionBannerProvider`
   - `shouldBlockClockInProvider`
   - `shouldWarnOnClockInProvider`

### Phase 3: Monitoring Service

7. **Create `PermissionMonitorService`** (`services/permission_monitor_service.dart`)
   - Timer-based polling during active shifts
   - Emits `PermissionChangeEvent` on changes
8. **Create `permissionMonitorProvider`** (same file or separate)

### Phase 4: UI Components

9. **Create `PermissionStatusBanner`** (`widgets/permission_status_banner.dart`)
   - Reads from `permissionGuardProvider`
   - Platform-specific styling and messaging
10. **Create `DeviceServicesDialog`** (`widgets/device_services_dialog.dart`)
    - For device GPS services disabled case
11. **Create `PermissionChangeAlert`** (`widgets/permission_change_alert.dart`)
    - For mid-shift permission changes
12. **Create `BatteryOptimizationDialog`** (`widgets/battery_optimization_dialog.dart`)
    - Android-only battery optimization prompt

### Phase 5: Integration

13. **Update `ShiftDashboardScreen`**
    - Add `PermissionStatusBanner` at top
    - Enhance `_handleClockIn()` with blocking/warning logic
    - Add lifecycle observer for permission re-check on resume
14. **Update `TrackingProvider`** (optional)
    - Listen to `permissionGuardProvider` for shift state sync
    - Start/stop monitoring on shift changes

### Phase 6: Testing

15. **Unit tests** for `PermissionGuardNotifier`
16. **Widget tests** for `PermissionStatusBanner`
17. **Integration tests** for full permission flow

---

## Key Code Snippets

### PermissionGuardNotifier (Core Logic)

```dart
class PermissionGuardNotifier extends StateNotifier<PermissionGuardState> {
  final Ref _ref;
  Timer? _debounceTimer;

  PermissionGuardNotifier(this._ref) : super(PermissionGuardState.initial()) {
    checkStatus();
  }

  Future<void> checkStatus() async {
    // Check device services
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final deviceStatus = serviceEnabled
        ? DeviceLocationStatus.enabled
        : DeviceLocationStatus.disabled;

    // Check app permission
    final permission = await BackgroundTrackingService.checkPermissions();

    // Check battery optimization (Android)
    final batteryOpt = await BackgroundTrackingService.isBatteryOptimizationDisabled;

    // Debounced update
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      state = state.copyWith(
        permission: permission,
        deviceStatus: deviceStatus,
        isBatteryOptimizationDisabled: batteryOpt,
        lastChecked: DateTime.now(),
      );
    });
  }

  void dismissWarning(DismissibleWarningType type) {
    state = state.copyWith(
      dismissedWarnings: {...state.dismissedWarnings, type},
    );
  }

  void setActiveShift(bool isActive) {
    state = state.copyWith(hasActiveShift: isActive);
    // Start/stop monitoring handled elsewhere
  }

  Future<void> requestPermission() async {
    await BackgroundTrackingService.requestPermissions();
    await checkStatus();
  }

  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  Future<void> openDeviceLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  Future<void> requestBatteryOptimization() async {
    await BackgroundTrackingService.requestBatteryOptimization();
    await checkStatus();
  }
}
```

### PermissionStatusBanner (UI Component)

```dart
class PermissionStatusBanner extends ConsumerWidget {
  const PermissionStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(permissionGuardProvider);
    if (!state.shouldShowBanner) return const SizedBox.shrink();

    final config = _getBannerConfig(state.status);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: config.backgroundColor,
        child: Row(
          children: [
            Icon(config.icon, color: config.iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(config.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(config.subtitle),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _handleAction(context, ref, state.status),
              child: Text(config.actionLabel),
            ),
            if (config.canDismiss)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => _handleDismiss(ref, state.status),
              ),
          ],
        ),
      ),
    );
  }
}
```

### ShiftDashboardScreen Integration

```dart
// In didChangeAppLifecycleState
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    ref.read(shiftProvider.notifier).refresh();
    ref.read(trackingProvider.notifier).refreshState();
    ref.read(permissionGuardProvider.notifier).checkStatus(); // NEW
  }
}

// In _handleClockIn
Future<void> _handleClockIn() async {
  final guardState = ref.read(permissionGuardProvider);

  // Block if critical permission issue
  if (guardState.shouldBlockClockIn) {
    await _handlePermissionBlock(guardState);
    return;
  }

  // Warn if partial permission
  if (guardState.shouldWarnOnClockIn) {
    final proceed = await _showPermissionWarning(guardState);
    if (!proceed) return;
  }

  // Existing clock-in logic...
}
```

---

## Testing Checklist

### Manual Testing

- [ ] Open app with all permissions denied → see banner with "Grant Permission"
- [ ] Open app with "while in use" only → see yellow warning banner
- [ ] Open app with "always" permission → no banner visible
- [ ] Tap dismiss on yellow warning → banner hides
- [ ] Restart app → yellow warning shows again
- [ ] Disable device location services → see red banner
- [ ] Tap "Grant Permission" → explanation dialog shows
- [ ] Grant permission → banner disappears
- [ ] Permanently deny permission → settings guidance shows
- [ ] Clock in with no permission → blocked with dialog
- [ ] Clock in with "while in use" → warning shown, can proceed
- [ ] During active shift, revoke permission → alert shown
- [ ] Restore permission during shift → tracking resumes

### Automated Testing

- [ ] `PermissionGuardNotifier` state transitions
- [ ] `PermissionGuardState` computed properties
- [ ] `PermissionStatusBanner` visibility by status
- [ ] `PermissionStatusBanner` action callbacks
- [ ] `PermissionMonitorService` change detection
- [ ] Integration: banner → dialog → permission grant → banner hidden

---

## Common Issues & Solutions

### Issue: Banner flickers on rapid permission changes
**Solution**: Debounce state updates with 500ms timer (implemented in `checkStatus()`)

### Issue: Banner shows when coming from background
**Solution**: Check permission on `AppLifecycleState.resumed` in lifecycle observer

### Issue: Battery optimization dialog not showing on iOS
**Solution**: Battery optimization is Android-only; guard with `Platform.isAndroid`

### Issue: Permission status wrong after granting in settings
**Solution**: Use `Geolocator.checkPermission()` not cached state on app resume

---

## File Checklist

```
lib/features/tracking/
├── models/
│   ├── device_location_status.dart           [NEW]
│   ├── permission_guard_status.dart          [NEW]
│   ├── permission_guard_state.dart           [NEW]
│   └── permission_change_event.dart          [NEW]
├── providers/
│   └── permission_guard_provider.dart        [NEW]
├── services/
│   └── permission_monitor_service.dart       [NEW]
└── widgets/
    ├── permission_status_banner.dart         [NEW]
    ├── device_services_dialog.dart           [NEW]
    ├── permission_change_alert.dart          [NEW]
    └── battery_optimization_dialog.dart      [NEW]

lib/features/shifts/screens/
└── shift_dashboard_screen.dart               [MODIFY]

test/features/tracking/
├── providers/
│   └── permission_guard_provider_test.dart   [NEW]
├── services/
│   └── permission_monitor_service_test.dart  [NEW]
└── widgets/
    └── permission_status_banner_test.dart    [NEW]
```
