import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/models/shift_enums.dart';
import '../../shifts/widgets/sync_status_indicator.dart';
import '../models/maintenance_session.dart';
import '../providers/maintenance_provider.dart';

/// Card showing the current active maintenance session with live timer.
class ActiveMaintenanceCard extends ConsumerStatefulWidget {
  const ActiveMaintenanceCard({super.key});

  @override
  ConsumerState<ActiveMaintenanceCard> createState() =>
      _ActiveMaintenanceCardState();
}

class _ActiveMaintenanceCardState
    extends ConsumerState<ActiveMaintenanceCard> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recalculateElapsed();
    });
  }

  void _recalculateElapsed() {
    final session = ref.read(activeMaintenanceSessionProvider);
    if (session != null && session.status.isActive) {
      setState(() {
        _elapsed = DateTime.now().difference(session.startedAt);
      });
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _completeSession() async {
    final notifier = ref.read(maintenanceSessionProvider.notifier);
    final success = await notifier.completeSession();

    if (!mounted) return;

    final errorMsg = ref.read(maintenanceSessionProvider).error;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(success
                  ? 'Session d\'entretien terminée'
                  : errorMsg ?? 'Erreur lors de la fermeture'),
            ),
          ],
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeMaintenanceSessionProvider);
    if (session == null) return const SizedBox.shrink();

    return _buildActiveSession(Theme.of(context), session);
  }

  Widget _buildActiveSession(ThemeData theme, MaintenanceSession session) {
    if (session.status.isActive) {
      _elapsed = DateTime.now().difference(session.startedAt);
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.orange.withValues(alpha: 0.4),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Entretien en cours',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ],
                ),
                SimpleSyncStatusIndicator(syncStatus: session.syncStatus),
              ],
            ),

            const SizedBox(height: 16),

            // Location info
            Row(
              children: [
                Icon(
                  Icons.apartment,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.buildingName,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (session.unitNumber != null)
                        Text(
                          session.unitNumber!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    session.unitNumber != null ? 'Appart.' : 'Bâtiment',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Live timer
            Center(
              child: Text(
                _formatDuration(_elapsed),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontFeatures: [const FontFeature.tabularFigures()],
                  letterSpacing: 2,
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Start time
            Center(
              child: Text(
                'Début: ${_formatTime(session.startedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Complete button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _completeSession,
                icon: const Icon(Icons.check_circle),
                label: const Text('Terminer la session'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }
}
