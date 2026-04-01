import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// OEM-specific battery optimization guide dialog (Android only).
///
/// Shown as a mandatory dialog when OEM battery killers are detected as
/// still active. "C'est fait" verifies actual battery optimization state
/// before dismissing.
class OemBatteryGuideDialog extends StatefulWidget {
  final String manufacturer;

  const OemBatteryGuideDialog({required this.manufacturer, super.key});

  static const _problematicOems = {
    'samsung', 'xiaomi', 'huawei', 'honor', 'oneplus', 'oppo', 'realme',
  };

  /// Show the OEM guide if:
  /// - Device is a known problematic OEM (Android only)
  /// - AND battery optimization is still active (actual state check)
  ///
  /// Pass [force] = true to show even when battery is already fixed
  /// (e.g. from the settings screen for re-education).
  static Future<void> showIfNeeded(
    BuildContext context, {
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final manufacturer = androidInfo.manufacturer.toLowerCase();
    if (!_problematicOems.contains(manufacturer)) return;

    // Check actual state — don't rely on the one-time flag
    final batteryOptDisabled =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (batteryOptDisabled && !force) return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // Mandatory — no tap-outside dismiss
      builder: (_) => OemBatteryGuideDialog(manufacturer: manufacturer),
    );
  }

  @override
  State<OemBatteryGuideDialog> createState() => _OemBatteryGuideDialogState();
}

class _OemBatteryGuideDialogState extends State<OemBatteryGuideDialog> {
  bool _hasOpenedSettings = false;
  bool _showNotFixedMessage = false;
  bool _isChecking = false;

  static const _channel =
      MethodChannel('gps_tracker/device_manufacturer');

  String get _title {
    switch (widget.manufacturer) {
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
    switch (widget.manufacturer) {
      case 'samsung':
        return [
          'Ouvrez Paramètres > Batterie > Limites d\'utilisation en arrière-plan',
          'Appuyez "Applications en veille prolongée" et retirez Tri-Logis Time',
          'Appuyez "Applications jamais en veille" et ajoutez Tri-Logis Time',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'xiaomi':
        return [
          'Ouvrez Paramètres > Applications > Gérer les applications',
          'Trouvez Tri-Logis Time et activez "Démarrage automatique"',
          'Appuyez Économie de batterie > Aucune restriction',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'huawei':
      case 'honor':
        return [
          'Ouvrez Paramètres > Batterie > Lancement d\'applications',
          'Trouvez Tri-Logis Time et désactivez la gestion automatique',
          'Activez : Lancement auto, Lancement secondaire, Exécution en arrière-plan',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'oneplus':
      case 'oppo':
      case 'realme':
        return [
          'Ouvrez Paramètres > Batterie > Optimisation de la batterie',
          'Trouvez Tri-Logis Time et sélectionnez "Ne pas optimiser"',
          'Activez "Autoriser l\'activité en arrière-plan"',
          'Revenez ici et appuyez "C\'est fait"',
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
              'Ces étapes sont requises pour un suivi continu :',
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
            if (_showNotFixedMessage) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        color: theme.colorScheme.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'L\'optimisation batterie est encore activée. '
                        'Vérifiez les étapes et réessayez.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _openDontKillMyApp,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('En savoir plus'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _isChecking ? null : _openOemSettings,
          child: const Text('Ouvrir les paramètres'),
        ),
        FilledButton(
          onPressed: (_isChecking || !_hasOpenedSettings)
              ? null
              : () => _confirmDone(context),
          child: _isChecking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text("C'est fait"),
        ),
      ],
    );
  }

  Future<void> _openOemSettings() async {
    setState(() => _hasOpenedSettings = true);
    try {
      await _channel.invokeMethod<bool>(
        'openOemBatterySettings',
        {'manufacturer': widget.manufacturer},
      );
    } catch (_) {}
  }

  Future<void> _openDontKillMyApp() async {
    final url = Uri.parse('https://dontkillmyapp.com/${widget.manufacturer}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _confirmDone(BuildContext context) async {
    setState(() {
      _isChecking = true;
      _showNotFixedMessage = false;
    });

    final isFixed = await FlutterForegroundTask.isIgnoringBatteryOptimizations;

    if (!mounted) return;

    if (!isFixed) {
      setState(() {
        _isChecking = false;
        _showNotFixedMessage = true;
      });
      return;
    }

    // Confirmed fixed — persist locally and close
    await FlutterForegroundTask.saveData(
        key: 'oem_setup_completed', value: true);
    await FlutterForegroundTask.saveData(
        key: 'oem_setup_manufacturer', value: widget.manufacturer);

    // Fire-and-forget: record completion server-side for admin visibility.
    unawaited(_syncCompletionToServer());

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _syncCompletionToServer() async {
    try {
      await Supabase.instance.client.schema('workforce').rpc<void>('mark_battery_setup_completed');
    } catch (_) {
      // Best-effort: local completion flag is source of truth for the app.
    }
  }
}
