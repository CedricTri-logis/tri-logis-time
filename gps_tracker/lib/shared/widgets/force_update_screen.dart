import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/shifts/services/version_check_service.dart';

/// Provider that checks app version against minimum_app_version in app_config.
/// Returns null if version is OK, or a VersionCheckResult if update is required.
final forceUpdateCheckProvider = FutureProvider<VersionCheckResult?>((ref) async {
  try {
    final client = Supabase.instance.client;
    final service = VersionCheckService(client);
    final result = await service.checkVersionForClockIn();
    return result.allowed ? null : result;
  } catch (_) {
    // Fail-open: if check fails, let the app through
    return null;
  }
});

/// Blocking screen shown when the app version is below minimum_app_version.
/// The user cannot dismiss this screen — they must update the app.
class ForceUpdateScreen extends StatelessWidget {
  final VersionCheckResult result;

  const ForceUpdateScreen({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.system_update,
                  size: 80,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 32),
                Text(
                  'Mise à jour requise',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  result.message ??
                      'Veuillez mettre à jour l\'application pour continuer.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                if (result.currentVersion != null)
                  Text(
                    'Version actuelle: ${result.currentVersion}\n'
                    'Version minimale: ${result.minimumVersion}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _openStore,
                  icon: const Icon(Icons.download),
                  label: const Text('Mettre à jour'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openStore() {
    final uri = Platform.isIOS
        ? Uri.parse('https://apps.apple.com/app/tri-logis-time/id6740043155')
        : Uri.parse(
            'https://play.google.com/store/apps/details?id=ca.trilogis.gps_tracker');
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
