import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Dialog explaining battery optimization (Android only).
class BatteryOptimizationDialog extends StatelessWidget {
  const BatteryOptimizationDialog({super.key});

  /// Show the dialog. No-op on iOS.
  /// Returns true if user allowed the optimization, false otherwise.
  static Future<bool> show(BuildContext context) async {
    // No-op on iOS
    if (!Platform.isAndroid) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const BatteryOptimizationDialog(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.battery_alert,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('Battery Optimization'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Android may pause GPS tracking to save battery when the app is in '
            'the background. To ensure uninterrupted tracking during your shifts, '
            'allow Tri-Logis Time to run without battery restrictions.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _buildInfoPoint(
            context,
            icon: Icons.work,
            text: 'Tracking only runs during active shifts',
          ),
          const SizedBox(height: 8),
          _buildInfoPoint(
            context,
            icon: Icons.timer,
            text: 'Location data is captured every few minutes',
          ),
          const SizedBox(height: 8),
          _buildInfoPoint(
            context,
            icon: Icons.battery_full,
            text: 'Battery impact is minimal',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: () async {
            final result = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
            if (context.mounted) {
              Navigator.of(context).pop(result);
            }
          },
          child: const Text('Allow'),
        ),
      ],
    );
  }

  Widget _buildInfoPoint(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
