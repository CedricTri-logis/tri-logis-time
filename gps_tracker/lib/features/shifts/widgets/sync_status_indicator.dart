import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shift_enums.dart';
import '../providers/sync_provider.dart';
import 'sync_detail_sheet.dart';

/// Widget showing the sync status of data.
/// Now enhanced with pending count badge and tap-to-details.
class SyncStatusIndicator extends ConsumerWidget {
  final bool showLabel;
  final bool showPendingCount;
  final bool tappable;

  const SyncStatusIndicator({
    super.key,
    this.showLabel = true,
    this.showPendingCount = true,
    this.tappable = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final syncStatus = syncState.status;
    final theme = Theme.of(context);

    final (icon, color, label) = switch (syncStatus) {
      SyncStatus.synced => (Icons.cloud_done, Colors.green, 'Synced'),
      SyncStatus.pending => (Icons.cloud_upload, Colors.orange, 'Pending'),
      SyncStatus.syncing => (Icons.cloud_sync, Colors.blue, 'Syncing'),
      SyncStatus.error => (Icons.cloud_off, Colors.red, 'Sync Error'),
    };

    // Build the indicator content
    Widget indicator;

    if (!showLabel) {
      indicator = Stack(
        clipBehavior: Clip.none,
        children: [
          syncStatus == SyncStatus.syncing
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              : Icon(icon, size: 20, color: color),
          if (showPendingCount && syncState.totalPending > 0)
            Positioned(
              top: -4,
              right: -4,
              child: _BadgeCount(count: syncState.totalPending),
            ),
        ],
      );
    } else {
      indicator = Container(
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
              _getLabel(syncState, label),
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
            // Show retry countdown if applicable
            if (syncState.nextRetryIn != null) ...[
              const SizedBox(width: 4),
              Text(
                '(${_formatCountdown(syncState.nextRetryIn!)})',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (!tappable) {
      return indicator;
    }

    return GestureDetector(
      onTap: () => SyncDetailSheet.show(context),
      child: indicator,
    );
  }

  String _getLabel(SyncState state, String baseLabel) {
    if (state.status == SyncStatus.syncing && state.progress != null) {
      return '${state.progress!.percentage.toStringAsFixed(0)}%';
    }
    if (showPendingCount && state.totalPending > 0) {
      return '$baseLabel (${state.totalPending})';
    }
    return baseLabel;
  }

  String _formatCountdown(Duration d) {
    if (d.inMinutes > 0) {
      return '${d.inMinutes}:${(d.inSeconds.remainder(60)).toString().padLeft(2, '0')}';
    }
    return '${d.inSeconds}s';
  }
}

class _BadgeCount extends StatelessWidget {
  final int count;

  const _BadgeCount({required this.count});

  @override
  Widget build(BuildContext context) {
    final displayCount = count > 99 ? '99+' : count.toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          displayCount,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// Simple sync status indicator without Riverpod (for legacy use).
class SimpleSyncStatusIndicator extends StatelessWidget {
  final SyncStatus syncStatus;
  final bool showLabel;

  const SimpleSyncStatusIndicator({
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
