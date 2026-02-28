# Samsung Battery Guard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Block clock-in when Samsung (or other OEMs) have put the app in a restricted standby bucket, guide the user through a 2-step fix, and report standby bucket to server for monitoring.

**Architecture:** Add `isAppStandbyRestricted` to the existing `shouldBlockClockIn` gate. Add a new `appStandbyRestricted` status to `PermissionGuardStatus`. Create a Samsung-specific 2-step dialog (app battery settings + never-sleeping list deeplink). Add `app_standby_bucket` column to `device_status` table and update the RPC + Dart service.

**Tech Stack:** Dart/Flutter (permission guard system), Kotlin (MainActivity native intents), PostgreSQL/Supabase (device_status migration + RPC)

---

### Task 1: Migration — Add `app_standby_bucket` to `device_status`

**Files:**
- Create: `supabase/migrations/091_device_status_standby_bucket.sql`

**Step 1: Write the migration**

```sql
-- Add app_standby_bucket column to device_status
ALTER TABLE device_status
ADD COLUMN app_standby_bucket TEXT;

-- Update upsert_device_status RPC to accept the new column
CREATE OR REPLACE FUNCTION upsert_device_status(
  p_notifications_enabled BOOLEAN,
  p_gps_permission TEXT,
  p_precise_location_enabled BOOLEAN,
  p_battery_optimization_disabled BOOLEAN,
  p_app_version TEXT,
  p_device_model TEXT,
  p_os_version TEXT,
  p_platform TEXT,
  p_app_standby_bucket TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  INSERT INTO device_status (
    employee_id,
    notifications_enabled,
    gps_permission,
    precise_location_enabled,
    battery_optimization_disabled,
    app_version,
    device_model,
    os_version,
    platform,
    app_standby_bucket,
    updated_at
  ) VALUES (
    auth.uid(),
    p_notifications_enabled,
    p_gps_permission,
    p_precise_location_enabled,
    p_battery_optimization_disabled,
    p_app_version,
    p_device_model,
    p_os_version,
    p_platform,
    p_app_standby_bucket,
    now()
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    notifications_enabled = EXCLUDED.notifications_enabled,
    gps_permission = EXCLUDED.gps_permission,
    precise_location_enabled = EXCLUDED.precise_location_enabled,
    battery_optimization_disabled = EXCLUDED.battery_optimization_disabled,
    app_version = EXCLUDED.app_version,
    device_model = EXCLUDED.device_model,
    os_version = EXCLUDED.os_version,
    platform = EXCLUDED.platform,
    app_standby_bucket = EXCLUDED.app_standby_bucket,
    updated_at = now();
END;
$$;
```

**Step 2: Apply the migration**

Run via Supabase MCP `apply_migration` tool.

**Step 3: Verify**

Query: `SELECT column_name FROM information_schema.columns WHERE table_name = 'device_status' AND column_name = 'app_standby_bucket';`

**Step 4: Commit**

```bash
git add supabase/migrations/091_device_status_standby_bucket.sql
git commit -m "feat: add app_standby_bucket column to device_status table and RPC"
```

---

### Task 2: Kotlin — Add Samsung "Never Sleeping" deeplink

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`

**Step 1: Add the new method call handler**

In `MainActivity.kt`, add a new case `"openSamsungNeverSleepingList"` to the device_manufacturer MethodChannel handler (after the `"openAppBatterySettings"` case, around line 46):

```kotlin
"openSamsungNeverSleepingList" -> {
    val opened = openSamsungNeverSleepingList()
    result.success(opened)
}
```

**Step 2: Add the native method**

Add after the `openAppBatterySettings()` method (around line 232):

```kotlin
/**
 * Opens Samsung's "Never sleeping apps" list directly via Samsung Deeplink API.
 * Falls back to Samsung Device Care battery page, then system battery settings.
 */
private fun openSamsungNeverSleepingList(): Boolean {
    val intents = listOf(
        // Samsung Deeplink API: activity_type 2 = "Never sleeping apps"
        Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY").apply {
            setPackage("com.samsung.android.lool")
            putExtra("activity_type", 2)
        },
        // Fallback: Samsung Device Care battery page
        Intent().setComponent(ComponentName(
            "com.samsung.android.lool",
            "com.samsung.android.lool.BatteryActivity"
        )),
        // Fallback: older Samsung Smart Manager
        Intent().setComponent(ComponentName(
            "com.samsung.android.sm",
            "com.samsung.android.sm.ui.battery.BatteryActivity"
        )),
        // Last resort: system battery settings
        Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
    )
    return tryStartIntents(intents)
}
```

**Step 3: Verify it compiles**

Run: `cd gps_tracker && flutter build apk --debug 2>&1 | tail -5`

**Step 4: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat: add Samsung 'Never sleeping apps' deeplink in MainActivity"
```

---

### Task 3: Dart — Add `openSamsungNeverSleepingList` to `AndroidBatteryHealthService`

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`

**Step 1: Add the method**

Add after the `openAppBatterySettings()` method (around line 109):

```dart
static Future<bool> openSamsungNeverSleepingList() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>(
          'openSamsungNeverSleepingList',
        ) ??
        false;
  } catch (_) {
    return false;
  }
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/android_battery_health_service.dart
git commit -m "feat: add openSamsungNeverSleepingList to AndroidBatteryHealthService"
```

---

### Task 4: Add `appStandbyRestricted` to `PermissionGuardStatus` and wire into state

**Files:**
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_status.dart`
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_state.dart`

**Step 1: Add the new enum value**

In `permission_guard_status.dart`, add `appStandbyRestricted` before `preciseLocationRequired`:

```dart
/// App is in restricted/rare standby bucket (Samsung sleeping or Android hibernation).
appStandbyRestricted,
```

**Step 2: Wire into `PermissionGuardState.status`**

In `permission_guard_state.dart`, in the `status` getter, add the check after `batteryOptimizationRequired` and before `preciseLocationRequired` (around line 76):

```dart
if (isAppStandbyRestricted) {
  return PermissionGuardStatus.appStandbyRestricted;
}
```

**Step 3: Wire into `shouldBlockClockIn`**

In `permission_guard_state.dart`, add `isAppStandbyRestricted` to the `shouldBlockClockIn` getter (around line 100):

```dart
bool get shouldBlockClockIn {
  return deviceStatus == DeviceLocationStatus.disabled ||
      !permission.hasAnyPermission ||
      permission.level == LocationPermissionLevel.whileInUse ||
      !isBatteryOptimizationDisabled ||
      isAppStandbyRestricted ||
      !isPreciseLocationEnabled;
}
```

**Step 4: Verify no compile errors**

Run: `cd gps_tracker && flutter analyze 2>&1 | tail -10`

**Step 5: Commit**

```bash
git add gps_tracker/lib/features/tracking/models/permission_guard_status.dart \
       gps_tracker/lib/features/tracking/models/permission_guard_state.dart
git commit -m "feat: add appStandbyRestricted to permission guard status and clock-in blocking"
```

---

### Task 5: Create Samsung Standby Restriction Dialog

**Files:**
- Create: `gps_tracker/lib/features/tracking/widgets/samsung_standby_dialog.dart`

**Step 1: Create the 2-step dialog**

```dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_battery_health_service.dart';

/// Samsung-specific 2-step dialog to fix standby bucket restriction.
///
/// Step 1: Open app battery settings → set to "Unrestricted"
/// Step 2: Open Samsung "Never sleeping apps" list → add Tri-Logis Time
class SamsungStandbyDialog extends StatefulWidget {
  const SamsungStandbyDialog({super.key});

  static Future<void> show(BuildContext context) async {
    if (!Platform.isAndroid) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const SamsungStandbyDialog(),
    );
  }

  @override
  State<SamsungStandbyDialog> createState() => _SamsungStandbyDialogState();
}

class _SamsungStandbyDialogState extends State<SamsungStandbyDialog> {
  int _currentStep = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.battery_alert, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          const Expanded(child: Text('Application restreinte')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Votre appareil a mis Tri-Logis Time en veille. '
              'Le suivi GPS sera interrompu pendant vos quarts.\n\n'
              'Suivez ces 2 étapes pour corriger :',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _buildStep(
              theme: theme,
              stepNumber: 1,
              title: 'Batterie de l\'application',
              description:
                  'Paramètres > Applis > Tri-Logis Time > Batterie\n'
                  '→ Sélectionnez "Non restreint"',
              isActive: _currentStep == 0,
              isCompleted: _currentStep > 0,
              onAction: () async {
                await AndroidBatteryHealthService.openAppBatterySettings();
                if (mounted) setState(() => _currentStep = 1);
              },
              actionLabel: 'Ouvrir',
            ),
            const SizedBox(height: 12),
            _buildStep(
              theme: theme,
              stepNumber: 2,
              title: 'Apps jamais en veille',
              description:
                  'Paramètres > Batterie > Limites d\'utilisation en arrière-plan\n'
                  '→ Appuyez "Apps jamais en veille"\n'
                  '→ Ajoutez Tri-Logis Time',
              isActive: _currentStep == 1,
              isCompleted: _currentStep > 1,
              onAction: () async {
                await AndroidBatteryHealthService
                    .openSamsungNeverSleepingList();
                if (mounted) setState(() => _currentStep = 2);
              },
              actionLabel: 'Ouvrir',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_currentStep >= 2 ? 'Terminé' : 'Vérifier'),
        ),
      ],
    );
  }

  Widget _buildStep({
    required ThemeData theme,
    required int stepNumber,
    required String title,
    required String description,
    required bool isActive,
    required bool isCompleted,
    required VoidCallback onAction,
    required String actionLabel,
  }) {
    final color = isCompleted
        ? Colors.green
        : isActive
            ? theme.colorScheme.primary
            : Colors.grey;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: isActive ? theme.colorScheme.primary : Colors.grey.shade300,
          width: isActive ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
        color: isActive
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isCompleted
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : Text(
                      '$stepNumber',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isCompleted ? Colors.green : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: theme.textTheme.bodySmall,
                ),
                if (isActive) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 32,
                    child: OutlinedButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(actionLabel),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

**Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze 2>&1 | tail -10`

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/widgets/samsung_standby_dialog.dart
git commit -m "feat: add Samsung 2-step standby restriction dialog"
```

---

### Task 6: Wire dialog into `PermissionStatusBanner` and `_handlePermissionBlock`

**Files:**
- Modify: `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Step 1: Add banner config for `appStandbyRestricted`**

In `permission_status_banner.dart`, in the `_getBannerConfig` switch (after `batteryOptimizationRequired` case, around line 174), add:

```dart
PermissionGuardStatus.appStandbyRestricted => _BannerConfig(
    backgroundColor: theme.colorScheme.errorContainer,
    iconColor: theme.colorScheme.onErrorContainer,
    icon: Icons.battery_alert,
    title: 'Application mise en veille',
    subtitle: 'Le suivi GPS sera interrompu — action requise',
    actionLabel: 'Corriger',
    canDismiss: false,
  ),
```

**Step 2: Add action handler for `appStandbyRestricted`**

In `_handleAction` switch, add before the `preciseLocationRequired` case:

```dart
case PermissionGuardStatus.appStandbyRestricted:
  if (context.mounted) {
    await SamsungStandbyDialog.show(context);
    // Re-check after dialog closes
    notifier.checkStatus();
  }
```

Add the import at the top of the file:

```dart
import 'samsung_standby_dialog.dart';
```

**Step 3: Add `appStandbyRestricted` handling in `_handlePermissionBlock`**

In `shift_dashboard_screen.dart`, in `_handlePermissionBlock`, add a case after the battery optimization check (after line 521) and before the precise location check:

```dart
} else if (guardState.isAppStandbyRestricted) {
  if (!mounted) return;
  await SamsungStandbyDialog.show(context);
```

Add the import at the top of `shift_dashboard_screen.dart`:

```dart
import '../../tracking/widgets/samsung_standby_dialog.dart';
```

**Step 4: Verify it compiles**

Run: `cd gps_tracker && flutter analyze 2>&1 | tail -10`

**Step 5: Commit**

```bash
git add gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart \
       gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: wire Samsung standby dialog into banner and clock-in block handler"
```

---

### Task 7: Report standby bucket in `DeviceStatusService`

**Files:**
- Modify: `gps_tracker/lib/shared/services/device_status_service.dart`

**Step 1: Add standby bucket to `reportStatus`**

Add a new async call in the `Future.wait` array (after `_checkBatteryOptimization()`):

```dart
_getAppStandbyBucket(),
```

Extract the result after `batteryOptDisabled` (add as index 4, shift deviceInfo to index 5):

```dart
final appStandbyBucket = results[4] as String?;
final deviceInfo = results[5] as Map<String, String>;
```

Add the new parameter to the RPC call:

```dart
'p_app_standby_bucket': appStandbyBucket,
```

**Step 2: Add the helper method**

Add after `_checkBatteryOptimization()`:

```dart
static Future<String?> _getAppStandbyBucket() async {
  if (Platform.isIOS) return null;
  try {
    final bucket = await AndroidBatteryHealthService.getAppStandbyBucket();
    return bucket.bucketName;
  } catch (_) {
    return null;
  }
}
```

**Step 3: Verify it compiles**

Run: `cd gps_tracker && flutter analyze 2>&1 | tail -10`

**Step 4: Commit**

```bash
git add gps_tracker/lib/shared/services/device_status_service.dart
git commit -m "feat: report app_standby_bucket to server in DeviceStatusService"
```

---

### Task 8: Final verification and build

**Step 1: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found.

**Step 2: Run flutter build**

Run: `cd gps_tracker && flutter build apk --debug 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL

**Step 3: Verify migration was applied**

Query:
```sql
SELECT app_standby_bucket FROM device_status LIMIT 1;
```
Expected: NULL values (no app has reported yet).

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: resolve any remaining issues from Samsung battery guard"
```
