import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cleaning/screens/qr_scanner_screen.dart';
import '../../shifts/widgets/sync_status_indicator.dart';
import '../models/activity_type.dart';
import '../models/work_session.dart';
import '../providers/work_session_provider.dart';

/// Unified card showing the current active work session with live timer,
/// or a prompt text when no session is active.
///
/// Replaces [ActiveSessionCard] (cleaning) + [ActiveMaintenanceCard] (maintenance)
/// with a single widget that adapts its display based on [ActivityType].
class ActiveWorkSessionCard extends ConsumerStatefulWidget {
  const ActiveWorkSessionCard({super.key});

  @override
  ConsumerState<ActiveWorkSessionCard> createState() =>
      _ActiveWorkSessionCardState();
}

class _ActiveWorkSessionCardState
    extends ConsumerState<ActiveWorkSessionCard> {
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
    final session = ref.read(activeWorkSessionProvider);
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
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _openScanner() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const QrScannerScreen()),
    );
  }

  Future<void> _completeSession() async {
    final notifier = ref.read(workSessionProvider.notifier);
    final result = await notifier.completeSession();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              result.success ? Icons.check_circle : Icons.error,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                result.success
                    ? 'Session terminée'
                    : result.errorMessage ?? 'Erreur lors de la fermeture',
              ),
            ),
          ],
        ),
        backgroundColor: result.success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Future<void> _manualClose() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text('Terminer sans scanner?')),
          ],
        ),
        content: const Text(
          'La session sera marquée comme fermée manuellement. '
          'Il est recommandé de scanner le code QR pour terminer normalement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Terminer'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final success =
        await ref.read(workSessionProvider.notifier).manualClose();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Text(
              success
                  ? 'Session terminée manuellement'
                  : 'Erreur lors de la fermeture',
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
    final session = ref.watch(activeWorkSessionProvider);
    final theme = Theme.of(context);

    if (session == null) {
      return _buildEmptyState(theme);
    }

    return _buildActiveSession(theme, session);
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Aucune session active',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Démarrez une activité pour commencer',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveSession(ThemeData theme, WorkSession session) {
    // Recalculate elapsed on each build for active sessions
    if (session.status.isActive) {
      _elapsed = DateTime.now().difference(session.startedAt);
    }

    final activityColor = session.activityType.color;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: activityColor.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: activity badge + sync status
            _buildHeader(theme, session, activityColor),

            const SizedBox(height: 16),

            // Location info
            _buildLocationInfo(theme, session, activityColor),

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

            // Action buttons
            _buildActionButtons(theme, session, activityColor),
          ],
        ),
      ),
    );
  }

  /// Header row with pulsing dot, activity type badge, and sync indicator.
  Widget _buildHeader(
    ThemeData theme,
    WorkSession session,
    Color activityColor,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              // Pulsing activity dot
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: activityColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: activityColor.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Activity type badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: activityColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: activityColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      session.activityType.icon,
                      size: 16,
                      color: activityColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${session.activityType.displayName} en cours',
                      style: TextStyle(
                        fontSize: 13,
                        color: activityColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SimpleSyncStatusIndicator(syncStatus: session.syncStatus),
      ],
    );
  }

  /// Location display adapts based on activity type:
  /// - Cleaning: studio number + building name + studio type badge
  /// - Maintenance: building name + unit number + location badge
  /// - Admin: "Bureau" label
  Widget _buildLocationInfo(
    ThemeData theme,
    WorkSession session,
    Color activityColor,
  ) {
    switch (session.activityType) {
      case ActivityType.cleaning:
        return _buildCleaningLocation(theme, session, activityColor);
      case ActivityType.maintenance:
        return _buildMaintenanceLocation(theme, session, activityColor);
      case ActivityType.admin:
        return _buildAdminLocation(theme, activityColor);
    }
  }

  Widget _buildCleaningLocation(
    ThemeData theme,
    WorkSession session,
    Color activityColor,
  ) {
    return Row(
      children: [
        Icon(
          Icons.meeting_room,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.studioNumber ?? session.studioId ?? '',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (session.buildingName != null)
                Text(
                  session.buildingName!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (session.studioType != null)
          _LocationBadge(
            label: session.studioType!,
            color: activityColor,
          ),
      ],
    );
  }

  Widget _buildMaintenanceLocation(
    ThemeData theme,
    WorkSession session,
    Color activityColor,
  ) {
    return Row(
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
                session.buildingName ?? '',
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
        _LocationBadge(
          label: session.unitNumber != null ? 'Appart.' : 'Bâtiment',
          color: activityColor,
        ),
      ],
    );
  }

  Widget _buildAdminLocation(ThemeData theme, Color activityColor) {
    return Row(
      children: [
        Icon(
          Icons.business_center,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Bureau',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        _LocationBadge(
          label: 'Admin',
          color: activityColor,
        ),
      ],
    );
  }

  /// Action buttons adapt based on activity type:
  /// - Cleaning: "Scanner pour terminer" + "Terminer" + "Terminer sans scanner"
  /// - Maintenance/Admin: "Terminer" only
  Widget _buildActionButtons(
    ThemeData theme,
    WorkSession session,
    Color activityColor,
  ) {
    return Column(
      children: [
        // "Scanner pour terminer" — cleaning only
        if (session.activityType.supportsQrScan) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openScanner,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scanner pour terminer'),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // "Terminer" — all types
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _completeSession,
            icon: const Icon(Icons.check_circle),
            label: const Text('Terminer'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
            ),
          ),
        ),

        // "Terminer sans scanner" — cleaning fallback only
        if (session.activityType.supportsQrScan) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _manualClose,
              icon: Icon(
                Icons.stop_circle_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              label: Text(
                'Terminer sans scanner',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Badge showing location type or studio type.
class _LocationBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _LocationBadge({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
