import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class ApprovalSummaryCard extends StatelessWidget {
  final DayApprovalDetail detail;
  const ApprovalSummaryCard({super.key, required this.detail});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isApproved = detail.approvalStatus == ApprovalStatus.approved;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isApproved ? Icons.check_circle : Icons.schedule,
                  color: isApproved ? Colors.green : Colors.grey,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  isApproved
                      ? 'Journ\u00e9e approuv\u00e9e'
                      : 'En attente d\'approbation',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isApproved
                        ? Colors.green.shade700
                        : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _StatChip(
                  label: 'Total',
                  value: _formatMinutes(detail.totalShiftMinutes),
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                _StatChip(
                  label: 'Approuv\u00e9',
                  value: _formatMinutes(detail.approvedMinutes),
                  color: Colors.green,
                ),
                if (detail.rejectedMinutes > 0) ...[
                  const SizedBox(width: 12),
                  _StatChip(
                    label: 'Rejet\u00e9',
                    value: _formatMinutes(detail.rejectedMinutes),
                    color: Colors.red,
                  ),
                ],
                if (detail.needsReviewCount > 0) ...[
                  const SizedBox(width: 12),
                  _StatChip(
                    label: '\u00c0 r\u00e9viser',
                    value: '${detail.needsReviewCount}',
                    color: Colors.orange,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style:
                  TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
