import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/providers/shift_provider.dart';
import '../../shifts/widgets/sync_status_indicator.dart';
import '../models/work_session.dart';
import '../providers/work_session_provider.dart';

/// Unified history list showing all work sessions (cleaning, maintenance, admin)
/// for the current shift.
///
/// Replaces both [CleaningHistoryList] and [MaintenanceHistoryList].
class WorkSessionHistoryList extends ConsumerStatefulWidget {
  const WorkSessionHistoryList({super.key});

  @override
  ConsumerState<WorkSessionHistoryList> createState() =>
      _WorkSessionHistoryListState();
}

class _WorkSessionHistoryListState
    extends ConsumerState<WorkSessionHistoryList> {
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
        ref.watch(shiftWorkSessionsProvider(activeShift.id));

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
              Icons.history,
              size: 32,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              'Aucune session ce quart',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    ThemeData theme,
    List<WorkSession> sessions,
  ) {
    // Sort by start time (newest first)
    final sorted = List<WorkSession>.from(sessions)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Historique des sessions',
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
                '${sorted.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...sorted.map((session) => _WorkSessionTile(session: session)),
      ],
    );
  }
}

class _WorkSessionTile extends StatelessWidget {
  final WorkSession session;

  const _WorkSessionTile({required this.session});

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

  (Color, String) _statusInfo() {
    switch (session.status) {
      case WorkSessionStatus.inProgress:
        return (Colors.blue, 'En cours');
      case WorkSessionStatus.completed:
        return (Colors.green, 'Termin\u00e9');
      case WorkSessionStatus.autoClosed:
        return (Colors.orange, 'Auto-ferm\u00e9');
      case WorkSessionStatus.manuallyClosed:
        return (Colors.orange.shade700, 'Ferm\u00e9');
    }
  }

  /// Location label based on activity type.
  String _locationLabel() {
    return session.locationLabel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (statusColor, statusLabel) = _statusInfo();
    final duration = session.duration;
    final activityType = session.activityType;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Activity type icon with color indicator
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: activityType.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                activityType.icon,
                color: activityType.color,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // Session info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _locationLabel(),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Status badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1,),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: statusColor.withValues(alpha: 0.3),),
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
                        const Icon(
                            Icons.flag,
                            color: Colors.orange,
                            size: 14,),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Duration + sync indicator
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
