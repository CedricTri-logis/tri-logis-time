import 'package:flutter/material.dart';

import '../models/dashboard_state.dart';
import 'live_shift_timer.dart';

/// Displays current shift status with active timer or clock-in prompt.
///
/// Shows:
/// - When active: Live timer with shift duration and green status indicator
/// - When inactive: Clock-in prompt with last clock-out time
class ShiftStatusTile extends StatelessWidget {
  final ShiftStatusInfo status;

  /// Optional callback when clock-in is requested.
  final VoidCallback? onClockIn;

  /// Optional last updated timestamp for cached data display.
  final DateTime? lastUpdated;

  const ShiftStatusTile({
    super.key,
    required this.status,
    this.onClockIn,
    this.lastUpdated,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with status indicator
            Row(
              children: [
                _StatusIndicator(isActive: status.isActive),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    status.isActive ? 'Currently Working' : 'Not Clocked In',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (lastUpdated != null)
                  _LastUpdatedBadge(lastUpdated: lastUpdated!),
              ],
            ),
            const SizedBox(height: 16),

            // Main content
            if (status.showLiveTimer && status.activeShift != null)
              _ActiveShiftContent(status: status)
            else
              _InactiveContent(
                status: status,
                onClockIn: onClockIn,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final bool isActive;

  const _StatusIndicator({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive ? Colors.green : Colors.grey,
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: Colors.green.withOpacity(0.4),
                  blurRadius: 6,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
    );
  }
}

class _ActiveShiftContent extends StatelessWidget {
  final ShiftStatusInfo status;

  const _ActiveShiftContent({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shift = status.activeShift!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Timer display
        Center(
          child: LiveShiftTimer(shift: shift),
        ),
        const SizedBox(height: 12),
        // Clock-in time
        Text(
          'Started at ${_formatTime(shift.clockedInAt)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    final localTime = time.toLocal();
    final hour = localTime.hour;
    final minute = localTime.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:$minute $period';
  }
}

class _InactiveContent extends StatelessWidget {
  final ShiftStatusInfo status;
  final VoidCallback? onClockIn;

  const _InactiveContent({
    required this.status,
    this.onClockIn,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Icons.schedule_outlined,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          'Ready to start your shift?',
          style: theme.textTheme.bodyLarge,
        ),
        if (status.lastClockOutAt != null) ...[
          const SizedBox(height: 4),
          Text(
            'Last shift ended ${_formatRelativeTime(status.lastClockOutAt!)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (onClockIn != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onClockIn,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Clock In'),
          ),
        ],
      ],
    );
  }

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }
}

class _LastUpdatedBadge extends StatelessWidget {
  final DateTime lastUpdated;

  const _LastUpdatedBadge({required this.lastUpdated});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = DateTime.now().difference(lastUpdated);

    String text;
    if (diff.inMinutes < 1) {
      text = 'Just now';
    } else if (diff.inMinutes < 60) {
      text = '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      text = '${diff.inHours}h ago';
    } else {
      text = '${diff.inDays}d ago';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
