import 'package:flutter/material.dart';

import '../models/permission_change_event.dart';

/// Alert dialog for permission changes during active shift.
class PermissionChangeAlert extends StatelessWidget {
  /// The permission change event that triggered this alert.
  final PermissionChangeEvent event;

  /// Callback when user acknowledges the alert.
  final VoidCallback? onAcknowledge;

  /// Callback when user chooses to fix the issue.
  final VoidCallback? onFix;

  const PermissionChangeAlert({
    required this.event,
    this.onAcknowledge,
    this.onFix,
    super.key,
  });

  /// Show the alert.
  static Future<void> show(
    BuildContext context,
    PermissionChangeEvent event, {
    VoidCallback? onAcknowledge,
    VoidCallback? onFix,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PermissionChangeAlert(
        event: event,
        onAcknowledge: onAcknowledge,
        onFix: onFix,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Determine alert type based on event
    final isRevoked = event.affectsTracking && !event.newState.hasAnyPermission;
    final isDowngraded =
        event.isDowngrade && event.newState.hasAnyPermission;

    final String title;
    final String body;
    final String fixLabel;
    final IconData icon;
    final Color iconColor;

    if (isRevoked) {
      title = 'Permission de localisation révoquée';
      body = 'Le suivi de localisation a été arrêté car la permission a été révoquée. '
          'Votre quart est toujours actif mais les données de localisation ne seront pas enregistrées.';
      fixLabel = 'Corriger maintenant';
      icon = Icons.location_off;
      iconColor = theme.colorScheme.error;
    } else if (isDowngraded) {
      title = 'Suivi en arrière-plan limité';
      body = "La permission de localisation en arrière-plan a été modifiée. Le suivi peut être "
          "interrompu lorsque l'application n'est pas visible.";
      fixLabel = 'Restaurer';
      icon = Icons.warning_amber;
      iconColor = Colors.orange;
    } else {
      // Generic downgrade case
      title = 'Permission modifiée';
      body = 'Votre permission de localisation a changé. Cela peut affecter le suivi GPS.';
      fixLabel = 'Corriger';
      icon = Icons.info_outline;
      iconColor = theme.colorScheme.primary;
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: Text(
        body,
        style: theme.textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            onAcknowledge?.call();
          },
          child: const Text('OK'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            onFix?.call();
          },
          child: Text(fixLabel),
        ),
      ],
    );
  }
}
