import 'package:flutter/material.dart';

import '../models/dashboard_state.dart';

/// Card displaying today's work statistics.
///
/// Shows:
/// - Total hours worked today (including active shift)
/// - Number of completed shifts
class DailySummaryCard extends StatelessWidget {
  final DailyStatistics stats;

  const DailySummaryCard({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.today,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Today',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              stats.formattedHours,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _shiftsLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _shiftsLabel {
    final count = stats.completedShiftCount;
    if (count == 0) {
      if (stats.activeShiftDuration > Duration.zero) {
        return '1 shift in progress';
      }
      return 'No shifts yet';
    }
    if (count == 1) {
      return '1 shift completed';
    }
    return '$count shifts completed';
  }
}

/// Compact version for use in lists or smaller spaces.
class DailySummaryCompact extends StatelessWidget {
  final DailyStatistics stats;

  const DailySummaryCompact({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.access_time,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          stats.formattedHours,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
