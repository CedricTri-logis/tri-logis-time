import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/models/shift_enums.dart';
import '../../shifts/providers/shift_provider.dart';
import '../../shifts/widgets/sync_status_indicator.dart';
import '../models/cleaning_session.dart';
import '../models/studio.dart';
import '../providers/cleaning_session_provider.dart';

/// List showing all cleaning sessions for the current shift.
class CleaningHistoryList extends ConsumerStatefulWidget {
  const CleaningHistoryList({super.key});

  @override
  ConsumerState<CleaningHistoryList> createState() =>
      _CleaningHistoryListState();
}

class _CleaningHistoryListState extends ConsumerState<CleaningHistoryList> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Update every second for live timers on in-progress sessions
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeShift = ref.watch(activeShiftProvider);

    if (activeShift == null) return const SizedBox.shrink();

    final sessionsAsync =
        ref.watch(shiftCleaningSessionsProvider(activeShift.id));

    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty) {
          return _buildEmptyState(theme);
        }
        return _buildList(theme, sessions);
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.cleaning_services_outlined,
              size: 32,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              'Aucun studio nettoyé ce quart',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, List<CleaningSession> sessions) {
    final completed =
        sessions.where((s) => !s.status.isActive).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Historique de ménage',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$completed terminé${completed > 1 ? 's' : ''}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...sessions.map(
            (session) => _CleaningSessionTile(session: session)),
      ],
    );
  }
}

class _CleaningSessionTile extends StatelessWidget {
  final CleaningSession session;

  const _CleaningSessionTile({required this.session});

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    final s = duration.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  (Color, String) _statusInfo(ThemeData theme) {
    switch (session.status) {
      case CleaningSessionStatus.inProgress:
        return (Colors.blue, 'En cours');
      case CleaningSessionStatus.completed:
        return (Colors.green, 'Terminé');
      case CleaningSessionStatus.autoClosed:
        return (Colors.orange, 'Auto-fermé');
      case CleaningSessionStatus.manuallyClosed:
        return (Colors.orange.shade700, 'Fermé');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (statusColor, statusLabel) = _statusInfo(theme);
    final duration = session.duration;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Studio icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.meeting_room,
                color: statusColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // Studio info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        session.studioNumber ?? session.studioId,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (session.buildingName != null) ...[
                        Text(
                          ' — ',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            session.buildingName!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Status badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: statusColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            color: statusColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(session.startedAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (session.isFlagged) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.flag,
                            color: Colors.orange, size: 14),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Duration
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatDuration(duration),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                SimpleSyncStatusIndicator(
                  syncStatus: session.syncStatus,
                  showLabel: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
