import 'package:flutter/material.dart';

import '../models/route_stats.dart';

/// Display summary statistics for a route.
class RouteStatsCard extends StatelessWidget {
  final RouteStats stats;

  const RouteStatsCard({
    required this.stats,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Résumé du trajet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    icon: Icons.pin_drop,
                    label: 'Points',
                    value: '${stats.totalPoints}',
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.straighten,
                    label: 'Distance',
                    value: stats.formattedDistance,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    icon: Icons.timer,
                    label: 'Durée',
                    value: stats.formattedDuration,
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.gps_fixed,
                    label: 'Précision',
                    value: '${stats.highAccuracyPercentage.toStringAsFixed(0)}% high',
                    valueColor: stats.highAccuracyPercentage >= 90
                        ? Colors.green
                        : stats.highAccuracyPercentage >= 70
                            ? Colors.orange
                            : Colors.red,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
