import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_battery_health_service.dart';

/// Samsung-specific 2-step dialog to fix standby bucket restriction.
///
/// Step 1: Open app battery settings → set to "Unrestricted"
/// Step 2: Open Samsung "Never sleeping apps" list → add Tri-Logis Time
class SamsungStandbyDialog extends StatefulWidget {
  const SamsungStandbyDialog({super.key});

  static Future<void> show(BuildContext context) async {
    if (!Platform.isAndroid) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const SamsungStandbyDialog(),
    );
  }

  @override
  State<SamsungStandbyDialog> createState() => _SamsungStandbyDialogState();
}

class _SamsungStandbyDialogState extends State<SamsungStandbyDialog> {
  int _currentStep = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.battery_alert, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          const Expanded(child: Text('Application restreinte')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Votre appareil a mis Tri-Logis Time en veille. '
              'Le suivi GPS sera interrompu pendant vos quarts.\n\n'
              'Suivez ces 2 étapes pour corriger :',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _buildStep(
              theme: theme,
              stepNumber: 1,
              title: 'Batterie de l\'application',
              description:
                  'Paramètres > Applis > Tri-Logis Time > Batterie\n'
                  '→ Sélectionnez "Non restreint"',
              isActive: _currentStep == 0,
              isCompleted: _currentStep > 0,
              onAction: () async {
                await AndroidBatteryHealthService.openAppBatterySettings();
                if (mounted) setState(() => _currentStep = 1);
              },
              actionLabel: 'Ouvrir',
            ),
            const SizedBox(height: 12),
            _buildStep(
              theme: theme,
              stepNumber: 2,
              title: 'Apps jamais en veille',
              description:
                  'Paramètres > Batterie > Limites d\'utilisation en arrière-plan\n'
                  '→ Appuyez "Apps jamais en veille"\n'
                  '→ Ajoutez Tri-Logis Time',
              isActive: _currentStep == 1,
              isCompleted: _currentStep > 1,
              onAction: () async {
                await AndroidBatteryHealthService
                    .openSamsungNeverSleepingList();
                if (mounted) setState(() => _currentStep = 2);
              },
              actionLabel: 'Ouvrir',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_currentStep >= 2 ? 'Terminé' : 'Vérifier'),
        ),
      ],
    );
  }

  Widget _buildStep({
    required ThemeData theme,
    required int stepNumber,
    required String title,
    required String description,
    required bool isActive,
    required bool isCompleted,
    required VoidCallback onAction,
    required String actionLabel,
  }) {
    final color = isCompleted
        ? Colors.green
        : isActive
            ? theme.colorScheme.primary
            : Colors.grey;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: isActive ? theme.colorScheme.primary : Colors.grey.shade300,
          width: isActive ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
        color: isActive
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isCompleted
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : Text(
                      '$stepNumber',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isCompleted ? Colors.green : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: theme.textTheme.bodySmall,
                ),
                if (isActive) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 32,
                    child: OutlinedButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(actionLabel),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
