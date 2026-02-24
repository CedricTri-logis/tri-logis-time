import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/utils/timezone_formatter.dart';
import '../../shifts/models/shift.dart';

/// A card displaying shift summary information
///
/// Shows clock in/out times, duration, status, and location info.
class ShiftHistoryCard extends StatelessWidget {
  final Shift shift;
  final VoidCallback? onTap;
  final bool showDate;

  const ShiftHistoryCard({
    super.key,
    required this.shift,
    this.onTap,
    this.showDate = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
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
                children: [
                  // Status indicator
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _getStatusColor(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Date
                  if (showDate)
                    Text(
                      _formatDate(shift.clockedInAt),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const Spacer(),
                  // Duration badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _formatDuration(shift.duration),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Timezone indicator
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Times shown in ${TimezoneFormatter.compactTzIndicator}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
              // Clock times
              Row(
                children: [
                  Expanded(
                    child: _buildTimeInfo(
                      context,
                      label: 'Pointage',
                      time: shift.clockedInAt,
                      hasLocation: shift.clockInLocation != null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.arrow_forward,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: _buildTimeInfo(
                      context,
                      label: 'Dépointage',
                      time: shift.clockedOutAt,
                      hasLocation: shift.clockOutLocation != null,
                      isActive: shift.isActive,
                    ),
                  ),
                ],
              ),
              // GPS point count (if available)
              if (shift.gpsPointCount != null && shift.gpsPointCount! > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${shift.gpsPointCount} points GPS',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeInfo(
    BuildContext context, {
    required String label,
    DateTime? time,
    bool hasLocation = false,
    bool isActive = false,
  }) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (time != null)
              Text(
                _formatTime(time),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              )
            else if (isActive)
              Text(
                'Actif',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.green,
                  fontWeight: FontWeight.w500,
                ),
              )
            else
              Text(
                '--:--',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 4),
            if (hasLocation)
              Icon(
                Icons.location_on,
                size: 12,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ],
    );
  }

  Color _getStatusColor() {
    if (shift.isActive) return Colors.green;
    return Colors.blue;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final shiftDate = DateTime(date.year, date.month, date.day);

    if (shiftDate == today) {
      return 'Aujourd\'hui';
    } else if (shiftDate == today.subtract(const Duration(days: 1))) {
      return 'Hier';
    } else {
      return DateFormat.MMMd().format(date);
    }
  }

  String _formatTime(DateTime time) {
    return DateFormat.jm().format(time.toLocal());
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours == 0) {
      return '${minutes}m';
    } else if (minutes == 0) {
      return '${hours}h';
    } else {
      return '${hours}h ${minutes}m';
    }
  }
}
