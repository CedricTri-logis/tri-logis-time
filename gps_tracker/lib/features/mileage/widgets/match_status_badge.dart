import 'package:flutter/material.dart';
import '../models/trip.dart';

/// Compact badge showing the route matching status of a trip.
class MatchStatusBadge extends StatelessWidget {
  final Trip trip;
  final bool compact;

  const MatchStatusBadge({
    super.key,
    required this.trip,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, label, color, bgColor) = _statusConfig(trip.matchStatus);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: color),
          SizedBox(width: compact ? 3 : 4),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String, Color, Color) _statusConfig(String status) {
    switch (status) {
      case 'matched':
        return (
          Icons.check_circle_outline,
          'Vérifié',
          Colors.green.shade700,
          Colors.green.shade50,
        );
      case 'pending':
      case 'processing':
        return (
          Icons.schedule,
          'En cours',
          Colors.orange.shade700,
          Colors.orange.shade50,
        );
      case 'failed':
        return (
          Icons.info_outline,
          'Estimé',
          Colors.orange.shade700,
          Colors.orange.shade50,
        );
      case 'anomalous':
        return (
          Icons.warning_amber_rounded,
          'À vérifier',
          Colors.red.shade700,
          Colors.red.shade50,
        );
      default:
        return (
          Icons.info_outline,
          'Estimé',
          Colors.orange.shade700,
          Colors.orange.shade50,
        );
    }
  }
}
