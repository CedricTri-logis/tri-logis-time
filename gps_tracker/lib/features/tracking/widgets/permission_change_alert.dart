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
      title = 'Location Permission Revoked';
      body = 'Location tracking has stopped because permission was revoked. '
          'Your shift is still active but location data will not be recorded.';
      fixLabel = 'Fix Now';
      icon = Icons.location_off;
      iconColor = theme.colorScheme.error;
    } else if (isDowngraded) {
      title = 'Background Tracking Limited';
      body = 'Background location permission was changed. Tracking may be '
          'interrupted when the app is not visible.';
      fixLabel = 'Restore';
      icon = Icons.warning_amber;
      iconColor = Colors.orange;
    } else {
      // Generic downgrade case
      title = 'Permission Changed';
      body = 'Your location permission has changed. This may affect GPS tracking.';
      fixLabel = 'Fix';
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
