import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/permission_guard_provider.dart';
import '../screens/battery_health_screen.dart';

/// A small warning chip shown below the clock button when device settings
/// prevent reliable GPS tracking. Tapping opens the BatteryHealthScreen.
///
/// Only visible on Android and only when battery/standby blocks clock-in.
/// iOS location issues are shown via the PermissionStatusBanner only.
class ClockButtonSettingsWarning extends ConsumerWidget {
  const ClockButtonSettingsWarning({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();

    final guardState = ref.watch(permissionGuardProvider);

    final isBatteryBlock = !guardState.isBatteryOptimizationDisabled ||
        guardState.isAppStandbyRestricted;

    if (!isBatteryBlock) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const BatteryHealthScreen(),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.orange.shade400),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.battery_alert, size: 16, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Text(
                'Configuration requise',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade900,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward_ios,
                  size: 11, color: Colors.orange.shade700),
            ],
          ),
        ),
      ),
    );
  }
}
