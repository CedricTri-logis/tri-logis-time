import 'package:flutter/material.dart';
import '../models/mileage_summary.dart';

class MileageSummaryCard extends StatelessWidget {
  final MileageSummary summary;

  const MileageSummaryCard({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Résumé du kilométrage',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryItem(
                    icon: Icons.straighten,
                    value: '${summary.businessDistanceKm.toStringAsFixed(1)} km',
                    label: 'Affaires',
                    color: theme.colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: _SummaryItem(
                    icon: Icons.attach_money,
                    value: '\$${summary.estimatedReimbursement.toStringAsFixed(2)}',
                    label: 'Remboursement',
                    color: Colors.green.shade700,
                  ),
                ),
                Expanded(
                  child: _SummaryItem(
                    icon: Icons.directions_car,
                    value: '${summary.businessTripCount}',
                    label: 'Trajets',
                    color: Colors.blue.shade700,
                  ),
                ),
              ],
            ),
            if (summary.personalDistanceKm > 0) ...[
              const Divider(height: 24),
              Text(
                'Personnel : ${summary.personalDistanceKm.toStringAsFixed(1)} km (${summary.personalTripCount} trajets)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _SummaryItem({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey.shade600,
              ),
        ),
      ],
    );
  }
}
