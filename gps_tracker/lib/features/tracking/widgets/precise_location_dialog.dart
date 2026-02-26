import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Dialog guiding user to enable precise/exact location (Android 12+).
class PreciseLocationDialog extends StatelessWidget {
  const PreciseLocationDialog({super.key});

  /// Show the dialog.
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const PreciseLocationDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.gps_off,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Position exacte requise'),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'La position exacte (GPS) est désactivée pour Tri-Logis Time. '
            'Sans cette option, l\'application ne peut pas suivre vos déplacements '
            'avec précision pendant vos quarts.',
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
                  'Étapes pour activer :',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (Platform.isIOS) ...[
                  _buildStep(context, '1. Toucher « Ouvrir les réglages » ci-dessous'),
                  _buildStep(context, '2. Toucher Localisation'),
                  _buildStep(context, '3. Activer « Position exacte »'),
                ] else ...[
                  _buildStep(context, '1. Toucher « Ouvrir les paramètres » ci-dessous'),
                  _buildStep(context, '2. Toucher Autorisations'),
                  _buildStep(context, '3. Toucher Localisation'),
                  _buildStep(context, '4. Activer « Utiliser la position exacte »'),
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
          label: Text(
            Platform.isIOS ? 'Ouvrir les réglages' : 'Ouvrir les paramètres',
          ),
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
