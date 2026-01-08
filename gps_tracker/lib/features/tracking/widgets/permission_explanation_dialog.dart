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
                ? 'Background Location'
                : 'Location Permission',
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            forBackgroundPermission
                ? 'To track your location during shifts (even when the app is in the background), we need "Always" location permission.'
                : 'GPS Clock-In Tracker needs your location to record where you clock in and out.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _buildInfoRow(
            context,
            icon: Icons.work,
            text: 'Location is only tracked during active shifts',
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            icon: Icons.lock,
            text: 'Your location data is encrypted and secure',
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            icon: Icons.stop_circle,
            text: 'Tracking stops automatically when you clock out',
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
                        ? 'When prompted, select "Always Allow"'
                        : 'When prompted, select "Allow all the time"',
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
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: () {
            onContinue?.call();
            Navigator.of(context).pop(true);
          },
          child: const Text('Continue'),
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
