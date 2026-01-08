import 'package:flutter/material.dart';

import '../models/shift_enums.dart';

/// Widget showing the sync status of data.
class SyncStatusIndicator extends StatelessWidget {
  final SyncStatus syncStatus;
  final bool showLabel;

  const SyncStatusIndicator({
    super.key,
    required this.syncStatus,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (icon, color, label) = switch (syncStatus) {
      SyncStatus.synced => (Icons.cloud_done, Colors.green, 'Synced'),
      SyncStatus.pending => (Icons.cloud_upload, Colors.orange, 'Pending'),
      SyncStatus.syncing => (Icons.cloud_sync, Colors.blue, 'Syncing'),
      SyncStatus.error => (Icons.cloud_off, Colors.red, 'Sync Error'),
    };

    if (!showLabel) {
      return Icon(icon, size: 20, color: color);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (syncStatus == SyncStatus.syncing)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            )
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
