import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Dialog guiding user to enable device-level location services.
class DeviceServicesDialog extends StatelessWidget {
  const DeviceServicesDialog({super.key});

  /// Show the dialog.
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const DeviceServicesDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.location_off,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          const Text('Activer les services de localisation'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Les services de localisation sont désactivés sur votre appareil. Tri-Logis Time '
            'a besoin de la localisation pour suivre vos quarts de travail.',
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
                  _buildStep(context, '1. Ouvrir Réglages'),
                  _buildStep(context, '2. Toucher Confidentialité et sécurité'),
                  _buildStep(context, '3. Toucher Service de localisation'),
                  _buildStep(context, '4. Activer le service de localisation'),
                ] else ...[
                  _buildStep(context, '1. Toucher « Ouvrir les paramètres » ci-dessous'),
                  _buildStep(context, '2. Toucher Localisation'),
                  _buildStep(context, '3. Activer la localisation'),
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
            await Geolocator.openLocationSettings();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Ouvrir les paramètres'),
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
