import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../shifts/models/shift.dart';

/// List widget displaying recent shifts from the last 7 days.
///
/// Shows:
/// - Date and duration for each shift
/// - Status indicator (active/completed)
/// - Tap action to navigate to shift details
class RecentShiftsList extends StatelessWidget {
  final List<Shift> shifts;

  /// Callback when a shift is tapped.
  final void Function(Shift shift)? onShiftTap;

  /// Maximum number of shifts to display.
  final int maxShifts;

  /// Whether to show a "View All" button.
  final bool showViewAll;

  /// Callback for "View All" action.
  final VoidCallback? onViewAll;

  const RecentShiftsList({
    super.key,
    required this.shifts,
    this.onShiftTap,
    this.maxShifts = 5,
    this.showViewAll = true,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    if (shifts.isEmpty) {
      return const _EmptyState();
    }

    final displayShifts = shifts.take(maxShifts).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...displayShifts.map((shift) => _ShiftListItem(
              shift: shift,
              onTap: onShiftTap != null ? () => onShiftTap!(shift) : null,
            )),
        if (showViewAll && shifts.length > maxShifts) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: onViewAll,
              child: Text('Voir les ${shifts.length} quarts'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ShiftListItem extends StatelessWidget {
  final Shift shift;
  final VoidCallback? onTap;

  const _ShiftListItem({
    required this.shift,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Date column
              SizedBox(
                width: 48,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDay(shift.clockedInAt),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _formatMonth(shift.clockedInAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Details column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusBadge(isActive: shift.isActive),
                        const SizedBox(width: 8),
                        Text(
                          _formatTimeRange(shift),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDuration(shift.duration),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Chevron
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDay(DateTime dt) => DateFormat('d').format(dt.toLocal());

  String _formatMonth(DateTime dt) => DateFormat('MMM').format(dt.toLocal());

  String _formatTimeRange(Shift shift) {
    final start = DateFormat('h:mm a').format(shift.clockedInAt.toLocal());
    if (shift.clockedOutAt == null) {
      return '$start - maintenant';
    }
    final end = DateFormat('h:mm a').format(shift.clockedOutAt!.toLocal());
    return '$start - $end';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours == 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isActive;

  const _StatusBadge({required this.isActive});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isActive
            ? Colors.green.withOpacity(0.1)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isActive ? 'Actif' : 'Terminé',
        style: theme.textTheme.labelSmall?.copyWith(
          color: isActive ? Colors.green : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(
            Icons.history_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Aucun quart récent',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Vos quarts des 7 derniers jours apparaîtront ici',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
