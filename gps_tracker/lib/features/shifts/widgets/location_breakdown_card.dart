import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class LocationBreakdownCard extends StatelessWidget {
  final DayApprovalDetail detail;
  final void Function(String locationName, List<ApprovalActivity> stops)? onLocationTap;
  const LocationBreakdownCard({super.key, required this.detail, this.onLocationTap});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  IconData _iconForLocationType(String? type) {
    switch (type) {
      case 'office':
        return Icons.business;
      case 'building':
        return Icons.apartment;
      case 'vendor':
        return Icons.store;
      case 'gaz':
        return Icons.local_gas_station;
      case 'home':
        return Icons.home;
      case 'cafe_restaurant':
        return Icons.restaurant;
      default:
        return Icons.location_on;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byLocation = detail.activitiesByLocation;
    if (byLocation.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'R\u00e9partition par lieu',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...byLocation.entries.map((entry) {
              final locationName = entry.key;
              final stops = entry.value;
              final approvedMins = stops
                  .where((s) => s.finalStatus == ActivityFinalStatus.approved)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final rejectedMins = stops
                  .where((s) => s.finalStatus == ActivityFinalStatus.rejected)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final pendingMins = stops
                  .where(
                      (s) => s.finalStatus == ActivityFinalStatus.needsReview)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final locationType = stops.first.locationType;

              final hasTap = onLocationTap != null && stops.first.latitude != null;
              final row = Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      _iconForLocationType(locationType),
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        locationName,
                        style: theme.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (approvedMins > 0)
                      _MiniBadge(
                        text: _formatMinutes(approvedMins),
                        color: Colors.green,
                      ),
                    if (rejectedMins > 0) ...[
                      const SizedBox(width: 4),
                      _MiniBadge(
                        text: _formatMinutes(rejectedMins),
                        color: Colors.red,
                      ),
                    ],
                    if (pendingMins > 0) ...[
                      const SizedBox(width: 4),
                      _MiniBadge(
                        text: _formatMinutes(pendingMins),
                        color: Colors.orange,
                      ),
                    ],
                    if (hasTap) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ],
                ),
              );
              if (hasTap) {
                return InkWell(
                  onTap: () => onLocationTap!(locationName, stops),
                  borderRadius: BorderRadius.circular(8),
                  child: row,
                );
              }
              return row;
            }),
          ],
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _MiniBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
