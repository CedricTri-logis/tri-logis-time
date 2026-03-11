import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class ActivityTimeline extends StatelessWidget {
  final List<ApprovalActivity> activities;
  final void Function(ApprovalActivity activity)? onActivityTap;
  const ActivityTimeline({super.key, required this.activities, this.onActivityTap});

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  IconData _activityIcon(ApprovalActivity activity) {
    if (activity.isTrip) return Icons.directions_car;
    if (activity.isStop) return Icons.location_on;
    if (activity.isClockIn) return Icons.login;
    if (activity.isClockOut) return Icons.logout;
    if (activity.isLunch) return Icons.restaurant;
    if (activity.isGap) return Icons.warning_amber;
    return Icons.help_outline;
  }

  Color _statusColor(ActivityFinalStatus status) {
    switch (status) {
      case ActivityFinalStatus.approved:
        return Colors.green;
      case ActivityFinalStatus.rejected:
        return Colors.red;
      case ActivityFinalStatus.needsReview:
        return Colors.orange;
    }
  }

  String _activityLabel(ApprovalActivity activity) {
    if (activity.isTrip) {
      final from = activity.startLocationName ?? '?';
      final to = activity.endLocationName ?? '?';
      final dist = activity.distanceKm != null
          ? ' (${activity.distanceKm!.toStringAsFixed(1)} km)'
          : '';
      return '$from \u2192 $to$dist';
    }
    if (activity.isStop) return activity.locationName ?? 'Lieu inconnu';
    if (activity.isClockIn) return 'Pointage';
    if (activity.isClockOut) return 'D\u00e9pointage';
    if (activity.isLunch) return 'Pause d\u00eener';
    if (activity.isGap) return 'Interruption GPS';
    return activity.activityType;
  }

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Activit\u00e9s',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...activities.map((activity) => _ActivityRow(
                  activity: activity,
                  icon: _activityIcon(activity),
                  label: _activityLabel(activity),
                  time: _formatTime(activity.startedAt),
                  duration: _formatDuration(activity.durationMinutes),
                  statusColor: _statusColor(activity.finalStatus),
                  statusLabel: activity.finalStatus.displayName,
                  onTap: (activity.isStop || activity.isTrip) && onActivityTap != null
                      ? () => onActivityTap!(activity)
                      : null,
                )),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ApprovalActivity activity;
  final IconData icon;
  final String label;
  final String time;
  final String duration;
  final Color statusColor;
  final String statusLabel;
  final VoidCallback? onTap;

  const _ActivityRow({
    required this.activity,
    required this.icon,
    required this.label,
    required this.time,
    required this.duration,
    required this.statusColor,
    required this.statusLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final row = Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$time \u00b7 $duration',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
          ],
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: row,
      );
    }
    return row;
  }
}
