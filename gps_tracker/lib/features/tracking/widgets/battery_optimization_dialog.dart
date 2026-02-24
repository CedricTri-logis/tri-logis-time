import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'oem_battery_guide_dialog.dart';

/// Dialog explaining battery optimization (Android only).
class BatteryOptimizationDialog extends StatelessWidget {
  const BatteryOptimizationDialog({super.key});

  /// Show the dialog. No-op on iOS.
  /// Returns true if user allowed the optimization, false otherwise.
  /// After AOSP dialog, chains to OEM-specific guide if applicable.
  static Future<bool> show(BuildContext context) async {
    // No-op on iOS
    if (!Platform.isAndroid) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const BatteryOptimizationDialog(),
    );
    final allowed = result ?? false;

    // After AOSP dialog, show OEM-specific instructions if applicable
    if (allowed && context.mounted) {
      await OemBatteryGuideDialog.showIfNeeded(context);
    }

    return allowed;
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
          const Text('Optimisation de la batterie'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Android peut interrompre le suivi GPS pour économiser la batterie '
            "lorsque l'application est en arrière-plan. Pour assurer un suivi continu "
            'pendant vos quarts, autorisez Tri-Logis Time à fonctionner sans restriction de batterie.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _buildInfoPoint(
            context,
            icon: Icons.work,
            text: 'Le suivi ne fonctionne que pendant les quarts actifs',
          ),
          const SizedBox(height: 8),
          _buildInfoPoint(
            context,
            icon: Icons.timer,
            text: 'La position est enregistrée toutes les quelques minutes',
          ),
          const SizedBox(height: 8),
          _buildInfoPoint(
            context,
            icon: Icons.battery_full,
            text: "L'impact sur la batterie est minimal",
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () async {
            final result = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
            if (context.mounted) {
              Navigator.of(context).pop(result);
            }
          },
          child: const Text('Autoriser'),
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
