import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dismissible_warning_type.dart';
import '../models/permission_guard_status.dart';
import '../providers/permission_guard_provider.dart';
import 'samsung_standby_dialog.dart';

/// Configuration for banner display based on status.
class _BannerConfig {
  final Color backgroundColor;
  final Color iconColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool canDismiss;

  const _BannerConfig({
    required this.backgroundColor,
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.canDismiss,
  });
}

/// Banner widget showing permission status with call-to-action.
class PermissionStatusBanner extends ConsumerWidget {
  const PermissionStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(permissionGuardProvider);
    if (!state.shouldShowBanner) return const SizedBox.shrink();

    final config = _getBannerConfig(context, state.status);

    return Semantics(
      label: '${config.title}. ${config.subtitle}. Tap ${config.actionLabel} to resolve.',
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: config.backgroundColor,
          child: SafeArea(
            bottom: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon with minimum touch target for accessibility
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      config.icon,
                      color: config.iconColor,
                      size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        config.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: config.iconColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        config.subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: config.iconColor.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Action button with minimum touch target
                SizedBox(
                  height: 48,
                  child: TextButton(
                    onPressed: () => _handleAction(context, ref, state.status),
                    style: TextButton.styleFrom(
                      foregroundColor: config.iconColor,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(
                      config.actionLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                if (config.canDismiss)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      icon: Icon(Icons.close, color: config.iconColor),
                      onPressed: () => _handleDismiss(ref, state.status),
                      tooltip: 'Fermer',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _BannerConfig _getBannerConfig(
    BuildContext context,
    PermissionGuardStatus status,
  ) {
    final theme = Theme.of(context);

    return switch (status) {
      PermissionGuardStatus.deviceServicesDisabled => _BannerConfig(
          backgroundColor: theme.colorScheme.errorContainer,
          iconColor: theme.colorScheme.onErrorContainer,
          icon: Icons.location_off,
          title: 'Services de localisation désactivés',
          subtitle: 'Activez la localisation pour suivre les quarts',
          actionLabel: 'Activer',
          canDismiss: false,
        ),
      PermissionGuardStatus.permanentlyDenied => _BannerConfig(
          backgroundColor: theme.colorScheme.errorContainer,
          iconColor: theme.colorScheme.onErrorContainer,
          icon: Icons.location_disabled,
          title: 'Permission de localisation refusée',
          subtitle: 'Activez dans les paramètres de l\'appareil',
          actionLabel: 'Paramètres',
          canDismiss: false,
        ),
      PermissionGuardStatus.permissionRequired => _BannerConfig(
          backgroundColor: Colors.orange.shade100,
          iconColor: Colors.orange.shade900,
          icon: Icons.location_searching,
          title: 'Permission de localisation requise',
          subtitle: 'Accordez la permission pour suivre les quarts',
          actionLabel: 'Accorder',
          canDismiss: false,
        ),
      PermissionGuardStatus.partialPermission => _BannerConfig(
          backgroundColor: Colors.yellow.shade100,
          iconColor: Colors.yellow.shade900,
          icon: Icons.warning_amber,
          title: 'Suivi en arrière-plan limité',
          subtitle: 'Améliorez pour un suivi continu',
          actionLabel: 'Améliorer',
          canDismiss: true,
        ),
      PermissionGuardStatus.batteryOptimizationRequired => _BannerConfig(
          backgroundColor: Colors.yellow.shade100,
          iconColor: Colors.yellow.shade900,
          icon: Icons.battery_alert,
          title: 'Optimisation batterie activée',
          subtitle: 'Peut interrompre le suivi pendant les quarts',
          actionLabel: 'Désactiver',
          canDismiss: true,
        ),
      PermissionGuardStatus.appStandbyRestricted => _BannerConfig(
          backgroundColor: theme.colorScheme.errorContainer,
          iconColor: theme.colorScheme.onErrorContainer,
          icon: Icons.battery_alert,
          title: 'Application mise en veille',
          subtitle: 'Le suivi GPS sera interrompu — action requise',
          actionLabel: 'Corriger',
          canDismiss: false,
        ),
      PermissionGuardStatus.preciseLocationRequired => _BannerConfig(
          backgroundColor: theme.colorScheme.errorContainer,
          iconColor: theme.colorScheme.onErrorContainer,
          icon: Icons.gps_off,
          title: 'Position exacte désactivée',
          subtitle: 'Activez la position exacte pour le suivi GPS',
          actionLabel: 'Activer',
          canDismiss: false,
        ),
      PermissionGuardStatus.allGranted => _BannerConfig(
          // This case shouldn't be reached since shouldShowBanner is false
          backgroundColor: Colors.green.shade100,
          iconColor: Colors.green.shade900,
          icon: Icons.check_circle,
          title: 'Toutes les permissions accordées',
          subtitle: 'Prêt à suivre',
          actionLabel: '',
          canDismiss: false,
        ),
    };
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    PermissionGuardStatus status,
  ) async {
    final notifier = ref.read(permissionGuardProvider.notifier);

    switch (status) {
      case PermissionGuardStatus.deviceServicesDisabled:
        await notifier.openDeviceLocationSettings();
      case PermissionGuardStatus.permanentlyDenied:
        await notifier.openAppSettings();
      case PermissionGuardStatus.permissionRequired:
        await notifier.requestPermission();
      case PermissionGuardStatus.partialPermission:
        await notifier.requestPermission();
      case PermissionGuardStatus.batteryOptimizationRequired:
        await notifier.requestBatteryOptimization();
      case PermissionGuardStatus.appStandbyRestricted:
        if (context.mounted) {
          await SamsungStandbyDialog.show(context);
          notifier.checkStatus();
        }
      case PermissionGuardStatus.preciseLocationRequired:
        await notifier.openAppSettings();
      case PermissionGuardStatus.allGranted:
        // No action needed
        break;
    }
  }

  void _handleDismiss(WidgetRef ref, PermissionGuardStatus status) {
    final notifier = ref.read(permissionGuardProvider.notifier);

    final warningType = switch (status) {
      PermissionGuardStatus.partialPermission =>
        DismissibleWarningType.partialPermission,
      PermissionGuardStatus.batteryOptimizationRequired =>
        DismissibleWarningType.batteryOptimization,
      _ => null,
    };

    if (warningType != null) {
      notifier.dismissWarning(warningType);
    }
  }
}
