# Widget Contracts: Location Permission Guard

**Feature**: 007-location-permission-guard
**Date**: 2026-01-10

## Overview

This document defines the contracts for Flutter widgets that implement the Location Permission Guard UI.

---

## Widget: PermissionStatusBanner

**Location**: `lib/features/tracking/widgets/permission_status_banner.dart`

### Purpose

Displays a persistent banner at the top of the dashboard showing current permission status with actionable guidance.

### Contract

```dart
/// Banner widget showing permission status with call-to-action.
class PermissionStatusBanner extends ConsumerWidget {
  const PermissionStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref);
}
```

### Behavior by Status

| Status | Banner Color | Icon | Message | Primary Action | Dismissible |
|--------|--------------|------|---------|----------------|-------------|
| deviceServicesDisabled | Red | `location_off` | "Location services are disabled" | "Enable in Settings" | No |
| permanentlyDenied | Red | `location_disabled` | "Location permission denied" | "Open Settings" | No |
| permissionRequired | Orange | `location_searching` | "Location permission required" | "Grant Permission" | No |
| partialPermission | Yellow | `warning` | "Background tracking limited" | "Upgrade Permission" | Yes |
| batteryOptimizationRequired | Yellow | `battery_alert` | "Battery optimization may interrupt tracking" | "Disable Optimization" | Yes |
| allGranted | N/A | N/A | Banner not shown | N/A | N/A |

### Props (Implicit via Provider)

Reads from `permissionGuardProvider`:
- `status` - determines banner content
- `shouldShowBanner` - determines visibility
- `dismissWarning()` - called when dismiss tapped

### Visual Specification

```
┌─────────────────────────────────────────────────────────┐
│ [Icon] Message text here explaining the issue           │
│        [Primary Action Button]            [X Dismiss]   │
└─────────────────────────────────────────────────────────┘
```

- Height: Flexible (content-based), typically 60-80px
- Padding: 16px horizontal, 12px vertical
- Animation: `AnimatedSize` for show/hide transitions
- Position: Top of dashboard content area (pushes content down)

---

## Widget: PermissionGuardWrapper (Optional)

**Location**: `lib/shared/widgets/permission_guard_wrapper.dart`

### Purpose

Optional wrapper that can gate entire screens or sections based on permission status.

### Contract

```dart
/// Wrapper that checks permission status before showing child.
class PermissionGuardWrapper extends ConsumerWidget {
  /// The child to display when permissions are sufficient.
  final Widget child;

  /// Optional widget to show when permissions are insufficient.
  final Widget? fallback;

  /// Whether to only warn (true) or block (false) on insufficient permission.
  final bool warnOnly;

  const PermissionGuardWrapper({
    super.key,
    required this.child,
    this.fallback,
    this.warnOnly = false,
  });
}
```

### Behavior

- If `warnOnly = false` and `shouldBlockClockIn = true`: Shows `fallback` or default blocked UI
- If `warnOnly = true` and `shouldWarnOnClockIn = true`: Shows child with overlay warning
- Otherwise: Shows `child` normally

---

## Widget: PermissionExplanationDialog (Existing - Enhanced)

**Location**: `lib/features/tracking/widgets/permission_explanation_dialog.dart`

### Existing Contract (No Changes)

```dart
class PermissionExplanationDialog extends StatelessWidget {
  final bool forBackgroundPermission;
  final VoidCallback? onContinue;
  final VoidCallback? onCancel;

  static Future<bool> show(BuildContext context, {bool forBackgroundPermission = false});
}
```

### Usage by Permission Guard

Called from `PermissionStatusBanner` when user taps "Grant Permission" or "Upgrade Permission".

---

## Widget: SettingsGuidanceDialog (Existing - No Changes)

**Location**: `lib/features/tracking/widgets/settings_guidance_dialog.dart`

### Existing Contract

```dart
class SettingsGuidanceDialog extends StatelessWidget {
  static Future<void> show(BuildContext context);
}
```

### Usage by Permission Guard

Called from `PermissionStatusBanner` when user taps "Open Settings" for permanently denied state.

---

## Widget: DeviceServicesDialog (New)

**Location**: `lib/features/tracking/widgets/device_services_dialog.dart`

### Purpose

Displays guidance for enabling device-level location services (distinct from app permissions).

### Contract

```dart
/// Dialog guiding user to enable device-level location services.
class DeviceServicesDialog extends StatelessWidget {
  const DeviceServicesDialog({super.key});

  /// Show the dialog.
  static Future<void> show(BuildContext context);
}
```

### Content

```dart
// Title
'Enable Location Services'

// Body
'Location services are turned off on your device. GPS Tracker needs '
'location services to be enabled to track your work shifts.'

// Steps (Platform-specific)
// iOS:
'1. Open Settings'
'2. Tap Privacy & Security'
'3. Tap Location Services'
'4. Turn on Location Services'

// Android:
'1. Open Settings'
'2. Tap Location'
'3. Turn on Location'

// Actions
'Later' (dismiss)
'Open Settings' (opens device location settings)
```

---

## Widget: PermissionChangeAlert (New)

**Location**: `lib/features/tracking/widgets/permission_change_alert.dart`

### Purpose

Alert dialog shown when permission changes are detected during an active shift.

### Contract

```dart
/// Alert dialog for permission changes during active shift.
class PermissionChangeAlert extends StatelessWidget {
  /// The permission change event that triggered this alert.
  final PermissionChangeEvent event;

  /// Callback when user acknowledges the alert.
  final VoidCallback? onAcknowledge;

  /// Callback when user chooses to fix the issue.
  final VoidCallback? onFix;

  const PermissionChangeAlert({
    super.key,
    required this.event,
    this.onAcknowledge,
    this.onFix,
  });

  /// Show the alert.
  static Future<void> show(BuildContext context, PermissionChangeEvent event);
}
```

### Content by Event Type

#### Permission Revoked (hadAny → !hasAny)
```
Title: 'Location Permission Revoked'
Body: 'Location tracking has stopped because permission was revoked. '
      'Your shift is still active but location data will not be recorded.'
Actions: 'OK' (acknowledge), 'Fix Now' (open settings)
```

#### Permission Downgraded (always → whileInUse)
```
Title: 'Background Tracking Limited'
Body: 'Background location permission was changed. Tracking may be '
      'interrupted when the app is not visible.'
Actions: 'OK' (acknowledge), 'Restore' (request permission)
```

---

## Widget: BatteryOptimizationDialog (New)

**Location**: `lib/features/tracking/widgets/battery_optimization_dialog.dart`

### Purpose

Android-only dialog explaining battery optimization and requesting exemption.

### Contract

```dart
/// Dialog explaining battery optimization (Android only).
class BatteryOptimizationDialog extends StatelessWidget {
  const BatteryOptimizationDialog({super.key});

  /// Show the dialog. No-op on iOS.
  static Future<bool> show(BuildContext context);
}
```

### Content

```dart
// Title
'Battery Optimization'

// Body
'Android may pause GPS tracking to save battery when the app is in '
'the background. To ensure uninterrupted tracking during your shifts, '
'allow GPS Tracker to run without battery restrictions.'

// Info points
'• Tracking only runs during active shifts'
'• Location data is captured every few minutes'
'• Battery impact is minimal'

// Actions
'Not Now' → returns false
'Allow' → requests exemption, returns success
```

---

## Widget Integration: ShiftDashboardScreen

**Location**: `lib/features/shifts/screens/shift_dashboard_screen.dart`

### Required Changes

```dart
// Add permission banner at top of build method
@override
Widget build(BuildContext context) {
  final shouldShowBanner = ref.watch(shouldShowPermissionBannerProvider);

  return RefreshIndicator(
    onRefresh: () async {
      await ref.read(shiftProvider.notifier).refresh();
      await ref.read(permissionGuardProvider.notifier).checkStatus();
    },
    child: Column(
      children: [
        // NEW: Permission banner
        if (shouldShowBanner) const PermissionStatusBanner(),

        // Existing content wrapped in Expanded
        Expanded(
          child: SingleChildScrollView(
            // ... existing dashboard content
          ),
        ),
      ],
    ),
  );
}
```

### Clock-In Flow Enhancement

```dart
Future<void> _handleClockIn() async {
  final guardState = ref.read(permissionGuardProvider);

  // NEW: Check if blocked
  if (guardState.shouldBlockClockIn) {
    if (guardState.deviceStatus == DeviceLocationStatus.disabled) {
      await DeviceServicesDialog.show(context);
    } else if (guardState.permission.level == LocationPermissionLevel.deniedForever) {
      await SettingsGuidanceDialog.show(context);
    } else {
      final proceed = await PermissionExplanationDialog.show(context);
      if (proceed) {
        await ref.read(permissionGuardProvider.notifier).requestPermission();
      }
    }
    return;
  }

  // NEW: Check if warning needed
  if (guardState.shouldWarnOnClockIn) {
    final proceed = await _showClockInWarningDialog();
    if (!proceed) return;
  }

  // Existing clock-in logic...
}
```

---

## Accessibility Requirements

All widgets must support:

- **Screen readers**: Meaningful labels for all interactive elements
- **Large text**: Scale gracefully with system font size
- **Color blindness**: Don't rely solely on color; use icons and text
- **Touch targets**: Minimum 48x48dp for interactive elements

### Example Semantics

```dart
Semantics(
  label: 'Permission warning: Location permission required. '
         'Tap Grant Permission to enable location access.',
  child: PermissionStatusBanner(),
)
```

---

## Testing Contracts

### Unit Tests (Widget Tests)

```dart
// Test banner visibility by status
testWidgets('shows banner when permission required', (tester) async {
  // Mock permissionGuardProvider with permissionRequired status
  // Pump PermissionStatusBanner
  // Expect banner is visible with correct content
});

testWidgets('hides banner when all granted', (tester) async {
  // Mock permissionGuardProvider with allGranted status
  // Pump PermissionStatusBanner
  // Expect banner is not visible
});

testWidgets('dismisses warning and updates state', (tester) async {
  // Mock permissionGuardProvider with partialPermission status
  // Pump PermissionStatusBanner
  // Tap dismiss button
  // Verify dismissWarning called
});
```

### Integration Tests

```dart
// Test full flow from banner to permission grant
testWidgets('permission flow from banner to grant', (tester) async {
  // Start with permissionRequired state
  // Tap "Grant Permission" on banner
  // Verify explanation dialog shown
  // Tap "Continue"
  // Verify system permission requested
  // Simulate permission granted
  // Verify banner disappears
});
```
