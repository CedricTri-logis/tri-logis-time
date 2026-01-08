import 'package:flutter/material.dart';

import '../models/route_point.dart';

/// Bottom sheet showing details for a selected GPS point.
class PointDetailSheet extends StatelessWidget {
  final RoutePoint point;

  const PointDetailSheet({
    required this.point,
    super.key,
  });

  /// Show as modal bottom sheet.
  static Future<void> show(BuildContext context, RoutePoint point) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => PointDetailSheet(point: point),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    );
  }

  String get _formattedTime {
    final local = point.capturedAt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String get _formattedDate {
    final local = point.capturedAt.toLocal();
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${weekdays[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
  }

  String get _formattedCoordinates {
    final latDir = point.latitude >= 0 ? 'N' : 'S';
    final lngDir = point.longitude >= 0 ? 'E' : 'W';
    final lat = point.latitude.abs().toStringAsFixed(6);
    final lng = point.longitude.abs().toStringAsFixed(6);
    return '$lat° $latDir, $lng° $lngDir';
  }

  String get _accuracyLabel {
    if (point.accuracy == null) return 'Unknown';
    if (point.isHighAccuracy) return 'High';
    if (point.isLowAccuracy) return 'Low';
    return 'Medium';
  }

  Color _accuracyColor(BuildContext context) {
    if (point.accuracy == null) return Colors.grey;
    if (point.isHighAccuracy) return Colors.green;
    if (point.isLowAccuracy) return Colors.orange;
    return Colors.yellow.shade700;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Location Point',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          _DetailRow(
            icon: Icons.access_time,
            label: 'Time',
            value: _formattedTime,
          ),
          _DetailRow(
            icon: Icons.calendar_today,
            label: 'Date',
            value: _formattedDate,
          ),
          _DetailRow(
            icon: Icons.location_on,
            label: 'Coordinates',
            value: _formattedCoordinates,
          ),
          _DetailRow(
            icon: Icons.gps_fixed,
            label: 'Accuracy',
            value: point.accuracy != null
                ? '${point.accuracy!.toStringAsFixed(1)} meters ($_accuracyLabel)'
                : 'Unknown',
            valueColor: _accuracyColor(context),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
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
                    color: valueColor,
                    fontWeight:
                        valueColor != null ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
