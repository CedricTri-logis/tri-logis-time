import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Dialog guiding user to enable location permission in device settings.
class SettingsGuidanceDialog extends StatelessWidget {
  const SettingsGuidanceDialog({super.key});

  /// Show the dialog.
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const SettingsGuidanceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.settings,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('Enable Location'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Location permission was denied. To enable GPS tracking during shifts, please enable location access in your device settings.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Steps to enable:',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (Platform.isIOS) ...[
                  _buildStep(context, '1. Open Settings'),
                  _buildStep(context, '2. Find GPS Tracker'),
                  _buildStep(context, '3. Tap Location'),
                  _buildStep(context, '4. Select "Always"'),
                ] else ...[
                  _buildStep(context, '1. Tap "Open Settings" below'),
                  _buildStep(context, '2. Tap Permissions'),
                  _buildStep(context, '3. Tap Location'),
                  _buildStep(context, '4. Select "Allow all the time"'),
                ],
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Geolocator.openAppSettings();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open Settings'),
        ),
      ],
    );
  }

  Widget _buildStep(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
