import 'dart:io';

import 'package:flutter/material.dart';

/// Dialog explaining why location permissions are needed.
class PermissionExplanationDialog extends StatelessWidget {
  /// Whether to show the background permission explanation.
  final bool forBackgroundPermission;

  /// Callback when user taps continue.
  final VoidCallback? onContinue;

  /// Callback when user taps cancel.
  final VoidCallback? onCancel;

  const PermissionExplanationDialog({
    super.key,
    this.forBackgroundPermission = false,
    this.onContinue,
    this.onCancel,
  });

  /// Show the dialog and return whether user wants to continue.
  static Future<bool> show(
    BuildContext context, {
    bool forBackgroundPermission = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PermissionExplanationDialog(
        forBackgroundPermission: forBackgroundPermission,
      ),
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
            Icons.location_on,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            forBackgroundPermission
                ? 'Localisation en arrière-plan'
                : 'Permission de localisation',
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            forBackgroundPermission
                ? "Pour suivre votre position pendant les quarts (même quand l'application est en arrière-plan), nous avons besoin de la permission « Toujours »."
                : 'Tri-Logis Time a besoin de votre position pour enregistrer vos pointages.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _buildInfoRow(
            context,
            icon: Icons.work,
            text: "La localisation n'est suivie que pendant les quarts actifs",
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            icon: Icons.lock,
            text: 'Vos données de localisation sont chiffrées et sécurisées',
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            icon: Icons.stop_circle,
            text: "Le suivi s'arrête automatiquement au dépointage",
          ),
          if (forBackgroundPermission) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withAlpha(128),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Platform.isIOS
                        ? 'Lorsque demandé, sélectionnez « Toujours autoriser »'
                        : 'Lorsque demandé, sélectionnez « Autoriser en permanence »',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            onCancel?.call();
            Navigator.of(context).pop(false);
          },
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () {
            onContinue?.call();
            Navigator.of(context).pop(true);
          },
          child: const Text('Continuer'),
        ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, {required IconData icon, required String text}) {
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
