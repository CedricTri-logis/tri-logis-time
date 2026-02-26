import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/config/theme.dart';
import '../services/android_battery_health_service.dart';
import '../widgets/oem_battery_guide_dialog.dart';

class BatteryHealthScreen extends StatefulWidget {
  const BatteryHealthScreen({super.key});

  @override
  State<BatteryHealthScreen> createState() => _BatteryHealthScreenState();
}

class _BatteryHealthSnapshot {
  final bool batteryOptimizationDisabled;
  final AppStandbyBucketInfo standbyBucket;
  final String? manufacturer;

  const _BatteryHealthSnapshot({
    required this.batteryOptimizationDisabled,
    required this.standbyBucket,
    required this.manufacturer,
  });
}

class _BatteryHealthScreenState extends State<BatteryHealthScreen> {
  late Future<_BatteryHealthSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _load();
  }

  Future<_BatteryHealthSnapshot> _load() async {
    if (!Platform.isAndroid) {
      return const _BatteryHealthSnapshot(
        batteryOptimizationDisabled: true,
        standbyBucket: AppStandbyBucketInfo(
          supported: false,
          bucket: null,
          bucketName: null,
        ),
        manufacturer: null,
      );
    }

    final results = await Future.wait<dynamic>([
      AndroidBatteryHealthService.isBatteryOptimizationDisabled,
      AndroidBatteryHealthService.getAppStandbyBucket(),
      AndroidBatteryHealthService.getManufacturer(),
    ]);

    return _BatteryHealthSnapshot(
      batteryOptimizationDisabled: results[0] as bool,
      standbyBucket: results[1] as AppStandbyBucketInfo,
      manufacturer: results[2] as String?,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _snapshotFuture = _load();
    });
    await _snapshotFuture;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sante batterie'),
      ),
      body: FutureBuilder<_BatteryHealthSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data;
          if (data == null) {
            return const Center(
              child: Text('Impossible de lire l etat batterie.'),
            );
          }

          final standbyLabel = data.standbyBucket.supported
              ? (data.standbyBucket.bucketName ?? 'UNKNOWN')
              : 'Non supporte';
          final standbyOk =
              !data.standbyBucket.supported || !data.standbyBucket.isRestricted;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusTile(
                  title: 'Optimisation batterie',
                  subtitle: data.batteryOptimizationDisabled
                      ? 'Desactivee (OK)'
                      : 'Activee (a corriger)',
                  ok: data.batteryOptimizationDisabled,
                  actions: [
                    _ActionButton(
                      label: 'Corriger',
                      onPressed: () async {
                        await AndroidBatteryHealthService
                            .requestIgnoreBatteryOptimization();
                        if (!mounted) return;
                        await _refresh();
                      },
                    ),
                    _ActionButton(
                      label: 'Ouvrir reglages',
                      onPressed: () async {
                        await AndroidBatteryHealthService
                            .openBatteryOptimizationSettings();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _StatusTile(
                  title: 'Mise en veille Android (App Standby Bucket)',
                  subtitle: 'Etat: $standbyLabel',
                  ok: standbyOk,
                  actions: [
                    _ActionButton(
                      label: 'Ouvrir app',
                      onPressed: () async {
                        await AndroidBatteryHealthService
                            .openAppBatterySettings();
                      },
                    ),
                    _ActionButton(
                      label: 'Verifier a nouveau',
                      onPressed: _refresh,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _StatusTile(
                  title: 'Reglages constructeur',
                  subtitle: data.manufacturer == null
                      ? 'Constructeur inconnu'
                      : 'Constructeur: ${data.manufacturer}',
                  ok: true,
                  actions: [
                    _ActionButton(
                      label: 'Guide OEM',
                      onPressed: () async {
                        await OemBatteryGuideDialog.showIfNeeded(
                          context,
                          force: true,
                        );
                      },
                    ),
                    _ActionButton(
                      label: 'Ouvrir page OEM',
                      onPressed: () async {
                        final manufacturer = data.manufacturer;
                        if (manufacturer == null) return;
                        await AndroidBatteryHealthService
                            .openOemBatterySettings(manufacturer);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.2),
                    ),
                  ),
                  child: const Text(
                    'Astuce: apres chaque correction, revenez ici et tirez vers le bas pour verifier.',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool ok;
  final List<Widget> actions;

  const _StatusTile({
    required this.title,
    required this.subtitle,
    required this.ok,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle : Icons.warning_amber,
                  color: ok ? Colors.green : Colors.orange.shade800,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(subtitle),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: TriLogisColors.red,
      ),
      child: Text(label),
    );
  }
}
