import 'package:flutter/material.dart';

import '../models/history_statistics.dart';

/// Card widget displaying individual employee statistics
class StatisticsCard extends StatelessWidget {
  final HistoryStatistics statistics;
  final String? title;
  final VoidCallback? onTap;

  const StatisticsCard({
    super.key,
    required this.statistics,
    this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                Text(
                  title!,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Expanded(
                    child: _StatItem(
                      icon: Icons.schedule,
                      label: 'Total quarts',
                      value: statistics.totalShifts.toString(),
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Expanded(
                    child: _StatItem(
                      icon: Icons.access_time,
                      label: 'Total heures',
                      value: statistics.formattedTotalHours,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  Expanded(
                    child: _StatItem(
                      icon: Icons.timelapse,
                      label: 'Durée moy.',
                      value: statistics.formattedAverageDuration,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
              if (statistics.totalGpsPoints > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${statistics.totalGpsPoints} points GPS enregistrés',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      'Voir les détails',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.primary,
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
}

/// Card widget displaying team statistics for managers
class TeamStatisticsCard extends StatelessWidget {
  final TeamStatistics statistics;
  final String? title;
  final VoidCallback? onTap;

  const TeamStatisticsCard({
    super.key,
    required this.statistics,
    this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                Row(
                  children: [
                    Icon(
                      Icons.groups,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      title!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Expanded(
                    child: _StatItem(
                      icon: Icons.people,
                      label: 'Employés',
                      value: statistics.totalEmployees.toString(),
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Expanded(
                    child: _StatItem(
                      icon: Icons.schedule,
                      label: 'Total quarts',
                      value: statistics.totalShifts.toString(),
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _StatItem(
                      icon: Icons.access_time,
                      label: 'Total heures',
                      value: statistics.formattedTotalHours,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                  Expanded(
                    child: _StatItem(
                      icon: Icons.person,
                      label: 'Moy. quarts/employé',
                      value: statistics.averageShiftsPerEmployee.toStringAsFixed(1),
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              if (onTap != null) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      'Voir les détails',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.primary,
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
}

/// Individual statistic item
class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 20,
            color: color,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Compact statistics row for inline display
class StatisticsRow extends StatelessWidget {
  final HistoryStatistics statistics;

  const StatisticsRow({
    super.key,
    required this.statistics,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _CompactStatItem(
            label: 'Quarts',
            value: statistics.totalShifts.toString(),
          ),
          _CompactStatItem(
            label: 'Heures',
            value: statistics.formattedTotalHours,
          ),
          _CompactStatItem(
            label: 'Moy.',
            value: statistics.formattedAverageDuration,
          ),
        ],
      ),
    );
  }
}

class _CompactStatItem extends StatelessWidget {
  final String label;
  final String value;

  const _CompactStatItem({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
