import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/models/shift_enums.dart';
import '../../shifts/widgets/sync_status_indicator.dart';
import '../models/cleaning_session.dart';
import '../models/studio.dart';
import '../providers/cleaning_session_provider.dart';
import '../screens/qr_scanner_screen.dart';

/// Card showing the current active cleaning session with live timer,
/// or a prompt to scan a QR code when no session is active.
class ActiveSessionCard extends ConsumerStatefulWidget {
  const ActiveSessionCard({super.key});

  @override
  ConsumerState<ActiveSessionCard> createState() => _ActiveSessionCardState();
}

class _ActiveSessionCardState extends ConsumerState<ActiveSessionCard> {
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
    final session = ref.read(activeCleaningSessionProvider);
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

  void _openScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeCleaningSessionProvider);
    final theme = Theme.of(context);

    if (session == null) {
      return _buildEmptyState(theme);
    }

    return _buildActiveSession(theme, session);
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Card(
      elevation: 1,
      child: InkWell(
        onTap: _openScanner,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(
                Icons.qr_code_scanner,
                size: 40,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                'Scanner un code QR',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Démarrez une session de ménage',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveSession(ThemeData theme, CleaningSession session) {
    // Recalculate elapsed on each build
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
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withValues(alpha: 0.4),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Ménage en cours',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ),
                SimpleSyncStatusIndicator(syncStatus: session.syncStatus),
              ],
            ),

            const SizedBox(height: 16),

            // Studio info
            Row(
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
                        session.studioNumber ?? session.studioId,
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
                  _StudioTypeBadge(type: session.studioType!),
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

            // Scan to finish prompt
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openScanner,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scanner pour terminer'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudioTypeBadge extends StatelessWidget {
  final StudioType type;

  const _StudioTypeBadge({required this.type});

  Color get _color {
    switch (type) {
      case StudioType.unit:
        return Colors.blue;
      case StudioType.commonArea:
        return Colors.teal;
      case StudioType.conciergerie:
        return Colors.purple;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _color.withValues(alpha: 0.3)),
      ),
      child: Text(
        type.displayName,
        style: TextStyle(
          fontSize: 12,
          color: _color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
