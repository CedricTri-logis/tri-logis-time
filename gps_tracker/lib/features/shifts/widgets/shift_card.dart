import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/day_approval.dart';
import '../models/shift.dart';
import 'sync_status_indicator.dart';

/// Card widget for displaying a shift in the history list.
class ShiftCard extends ConsumerWidget {
  final Shift shift;
  final VoidCallback? onTap;
  final DayApprovalSummary? approval;

  const ShiftCard({
    super.key,
    required this.shift,
    this.onTap,
    this.approval,
  });

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatDate(DateTime dateTime) {
    final months = [
      'jan.', 'fév.', 'mars', 'avr.', 'mai', 'juin',
      'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'
    ];
    final weekdays = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
    return '${weekdays[dateTime.weekday - 1]} ${dateTime.day} ${months[dateTime.month - 1]}';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours == 0) {
      return '${minutes}m';
    }
    return '${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final localClockIn = shift.clockedInAt.toLocal();
    final localClockOut = shift.clockedOutAt?.toLocal();
    // TODO: Once lunch segments produce sibling shift data, calculate
    // total lunch from completed lunch segments. For now, show raw duration.
    const lunchDuration = Duration.zero;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDate(localClockIn),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SimpleSyncStatusIndicator(
                    syncStatus: shift.syncStatus,
                    showLabel: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _TimeBlock(
                    label: 'Pointage',
                    time: _formatTime(localClockIn),
                    icon: Icons.login,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 24),
                  if (shift.isCompleted && localClockOut != null)
                    _TimeBlock(
                      label: 'Dépointage',
                      time: _formatTime(localClockOut),
                      icon: Icons.logout,
                      color: Colors.red,
                    )
                  else
                    _TimeBlock(
                      label: 'Dépointage',
                      time: '--:--',
                      icon: Icons.logout,
                      color: theme.colorScheme.outline,
                    ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Travail',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (shift.isCompleted) ...[
                        Text(
                          _formatDuration(shift.duration - lunchDuration),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ] else
                        Text(
                          'En cours',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      if (lunchDuration.inMinutes > 0) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.restaurant,
                              size: 12,
                              color: Colors.orange.shade600,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatDuration(lunchDuration),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.orange.shade600,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              if (shift.clockInLocation != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Position enregistrée',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              // Show approval badge for completed shifts
              if (shift.isCompleted) ...[
                const SizedBox(height: 8),
                _ApprovalBadge(approval: approval),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeBlock extends StatelessWidget {
  final String label;
  final String time;
  final IconData icon;
  final Color color;

  const _TimeBlock({
    required this.label,
    required this.time,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          time,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ApprovalBadge extends StatelessWidget {
  final DayApprovalSummary? approval;
  const _ApprovalBadge({this.approval});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isApproved = approval?.status == ApprovalStatus.approved;
    final hasRejections = approval?.hasRejections ?? false;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isApproved
                ? Colors.green.withValues(alpha: 0.1)
                : Colors.grey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isApproved ? Icons.check_circle : Icons.schedule,
                size: 14,
                color: isApproved ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 4),
              Text(
                isApproved
                    ? '${_formatMinutes(approval!.approvedMinutes ?? 0)} approuv\u00e9'
                    : 'En attente',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isApproved
                      ? Colors.green.shade700
                      : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
        if (hasRejections) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cancel, size: 14, color: Colors.red),
                const SizedBox(width: 4),
                Text(
                  '${_formatMinutes(approval!.rejectedMinutes ?? 0)} rejet\u00e9',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
