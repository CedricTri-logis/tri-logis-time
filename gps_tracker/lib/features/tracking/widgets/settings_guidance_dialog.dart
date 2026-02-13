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
          const Text('Activer la localisation'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'La permission de localisation a été refusée. Pour activer le suivi GPS pendant vos quarts, veuillez activer l\'accès à la localisation dans les paramètres.',
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
                  'Étapes pour activer:',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (Platform.isIOS) ...[
                  _buildStep(context, '1. Ouvrir Réglages'),
                  _buildStep(context, '2. Trouver GPS Tracker'),
                  _buildStep(context, '3. Toucher Position'),
                  _buildStep(context, '4. Sélectionner "Toujours"'),
                ] else ...[
                  _buildStep(context, '1. Toucher "Ouvrir paramètres"'),
                  _buildStep(context, '2. Toucher Autorisations'),
                  _buildStep(context, '3. Toucher Position'),
                  _buildStep(context, '4. Sélectionner "Toujours autoriser"'),
                ],
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Geolocator.openAppSettings();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Ouvrir paramètres'),
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
