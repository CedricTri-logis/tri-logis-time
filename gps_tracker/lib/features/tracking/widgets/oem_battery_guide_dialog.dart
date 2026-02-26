import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';

/// OEM-specific battery optimization guide dialog (Android only).
///
/// Shows step-by-step instructions in French for Samsung, Xiaomi, Huawei,
/// and OnePlus/Oppo/Realme devices to disable aggressive battery killers
/// that bypass standard Android battery optimization.
class OemBatteryGuideDialog extends StatelessWidget {
  final String manufacturer;

  const OemBatteryGuideDialog({required this.manufacturer, super.key});

  static const _channel = MethodChannel('gps_tracker/device_manufacturer');

  static const _problematicOems = {
    'samsung',
    'xiaomi',
    'huawei',
    'honor',
    'oneplus',
    'oppo',
    'realme',
  };

  /// Show the OEM guide if the device is a known problematic OEM and the user
  /// hasn't completed setup yet. No-op on iOS.
  static Future<void> showIfNeeded(
    BuildContext context, {
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;

    if (!force) {
      final completed = await FlutterForegroundTask.getData<bool>(
        key: 'oem_setup_completed',
      );
      if (completed == true) return;
    }

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final manufacturer = androidInfo.manufacturer.lowercase();

    if (!_problematicOems.contains(manufacturer)) return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => OemBatteryGuideDialog(manufacturer: manufacturer),
    );
  }

  String get _title {
    switch (manufacturer) {
      case 'samsung':
        return 'Configuration Samsung';
      case 'xiaomi':
        return 'Configuration Xiaomi';
      case 'huawei':
        return 'Configuration Huawei';
      case 'honor':
        return 'Configuration Honor';
      case 'oneplus':
        return 'Configuration OnePlus';
      case 'oppo':
        return 'Configuration Oppo';
      case 'realme':
        return 'Configuration Realme';
      default:
        return 'Configuration batterie';
    }
  }

  List<String> get _steps {
    switch (manufacturer) {
      case 'samsung':
        return [
          'Ouvrez Paramètres > Batterie > Limites d\'utilisation en arrière-plan',
          'Appuyez "Applications en veille prolongée"',
          'Retirez Tri-Logis Time de la liste',
          'Appuyez "Applications jamais en veille"',
          'Ajoutez Tri-Logis Time',
        ];
      case 'xiaomi':
        return [
          'Ouvrez Paramètres > Applications > Gérer les applications',
          'Trouvez Tri-Logis Time',
          'Activez "Démarrage automatique"',
          'Appuyez Économie de batterie > Aucune restriction',
        ];
      case 'huawei':
        return [
          'Ouvrez Paramètres > Batterie > Lancement d\'applications',
          'Trouvez Tri-Logis Time',
          'Désactivez la gestion automatique',
          'Activez les 3 options : Lancement auto, Lancement secondaire, Exécution en arrière-plan',
        ];
      case 'honor':
        return [
          'Ouvrez Paramètres > Batterie > Lancement d\'applications',
          'Trouvez Tri-Logis Time',
          'Désactivez la gestion automatique',
          'Activez les 3 options : Lancement auto, Lancement secondaire, Exécution en arrière-plan',
        ];
      case 'oneplus':
      case 'oppo':
      case 'realme':
        return [
          'Ouvrez Paramètres > Batterie > Optimisation de la batterie',
          'Trouvez Tri-Logis Time',
          'Sélectionnez "Ne pas optimiser"',
          'Activez "Autoriser l\'activité en arrière-plan"',
        ];
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.phone_android, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(_title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Votre appareil peut interrompre le suivi GPS en arrière-plan. '
              'Suivez ces étapes pour assurer un suivi continu :',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ...List.generate(_steps.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _steps[i],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: () => _openDontKillMyApp(),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('En savoir plus'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        OutlinedButton(
          onPressed: () => _openOemSettings(),
          child: const Text('Ouvrir les paramètres'),
        ),
        FilledButton(
          onPressed: () => _markCompleted(context),
          child: const Text("C'est fait"),
        ),
      ],
    );
  }

  Future<void> _openOemSettings() async {
    try {
      await _channel.invokeMethod<bool>(
        'openOemBatterySettings',
        {'manufacturer': manufacturer},
      );
    } catch (_) {
      // Best-effort — settings screen may not exist on this ROM version
    }
  }

  Future<void> _openDontKillMyApp() async {
    final url = Uri.parse('https://dontkillmyapp.com/$manufacturer');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort
    }
  }

  Future<void> _markCompleted(BuildContext context) async {
    await FlutterForegroundTask.saveData(
      key: 'oem_setup_completed',
      value: true,
    );
    await FlutterForegroundTask.saveData(
      key: 'oem_setup_manufacturer',
      value: manufacturer,
    );
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

extension on String {
  String lowercase() => toLowerCase();
}
