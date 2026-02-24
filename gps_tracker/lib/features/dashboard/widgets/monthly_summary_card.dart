import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../history/models/history_statistics.dart';

/// Card displaying this month's work statistics.
///
/// Shows:
/// - Total hours worked this month
/// - Total number of shifts
/// - Average shift duration (optional)
class MonthlySummaryCard extends StatelessWidget {
  final HistoryStatistics stats;

  /// Whether to show average shift duration.
  final bool showAverage;

  const MonthlySummaryCard({
    super.key,
    required this.stats,
    this.showAverage = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final monthName = DateFormat('MMMM', 'fr_CA').format(DateTime.now());

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
                  Icons.calendar_month,
                  size: 20,
                  color: colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  monthName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              stats.formattedTotalHours,
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
            if (showAverage && stats.hasData) ...[
              const SizedBox(height: 8),
              Text(
                'Moy. : ${stats.formattedAverageDuration}/quart',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _shiftsLabel {
    final count = stats.totalShifts;
    if (count == 0) return 'Aucun quart pour l\'instant';
    if (count == 1) return '1 quart';
    return '$count quarts';
  }
}

/// Compact version for use in lists or smaller spaces.
class MonthlySummaryCompact extends StatelessWidget {
  final HistoryStatistics stats;

  const MonthlySummaryCompact({
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
          Icons.calendar_today,
          size: 16,
          color: theme.colorScheme.secondary,
        ),
        const SizedBox(width: 4),
        Text(
          stats.formattedTotalHours,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'ce mois-ci',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
