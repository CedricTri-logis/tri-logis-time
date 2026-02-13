import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shift_enums.dart';
import '../providers/sync_provider.dart';
import '../providers/storage_provider.dart';

/// Bottom sheet showing detailed sync status and storage information.
class SyncDetailSheet extends ConsumerWidget {
  const SyncDetailSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const SyncDetailSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final storageState = ref.watch(storageProvider);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Title
                Text(
                  'Sync Status',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),

                // Status card
                _SyncStatusCard(syncState: syncState),
                const SizedBox(height: 16),

                // Progress (if syncing)
                if (syncState.status == SyncStatus.syncing &&
                    syncState.progress != null) ...[
                  _SyncProgressCard(syncState: syncState),
                  const SizedBox(height: 16),
                ],

                // Pending data
                if (syncState.hasPendingData) ...[
                  _PendingDataCard(syncState: syncState),
                  const SizedBox(height: 16),
                ],

                // Retry information
                if (syncState.isRetrying) ...[
                  _RetryInfoCard(syncState: syncState),
                  const SizedBox(height: 16),
                ],

                // Storage section
                _StorageCard(storageState: storageState, ref: ref),
                const SizedBox(height: 16),

                // Actions
                _ActionsSection(
                  syncState: syncState,
                  ref: ref,
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SyncStatusCard extends StatelessWidget {
  final SyncState syncState;

  const _SyncStatusCard({required this.syncState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (icon, color, title, subtitle) = switch (syncState.status) {
      SyncStatus.synced => (
          Icons.cloud_done,
          Colors.green,
          'All Synced',
          syncState.lastSyncTime != null
              ? 'Last sync: ${_formatDateTime(syncState.lastSyncTime!)}'
              : 'No pending data',
        ),
      SyncStatus.pending => (
          Icons.cloud_upload,
          Colors.orange,
          'Pending Sync',
          '${syncState.totalPending} items waiting to sync',
        ),
      SyncStatus.syncing => (
          Icons.sync,
          Colors.blue,
          'Syncing...',
          syncState.progress?.currentOperation ?? 'Processing data...',
        ),
      SyncStatus.error => (
          Icons.cloud_off,
          Colors.red,
          'Sync Error',
          syncState.lastError ?? 'An error occurred during sync',
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: syncState.status == SyncStatus.syncing
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'À l\'instant';
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return 'Il y a ${diff.inDays}j';
  }
}

class _SyncProgressCard extends StatelessWidget {
  final SyncState syncState;

  const _SyncProgressCard({required this.syncState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = syncState.progress!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Progress',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  '${progress.percentage.toStringAsFixed(0)}%',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress.percentage / 100,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ProgressItem(
                  label: 'Shifts',
                  value: '${progress.syncedShifts}/${progress.totalShifts}',
                ),
                _ProgressItem(
                  label: 'GPS Points',
                  value:
                      '${progress.syncedGpsPoints}/${progress.totalGpsPoints}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressItem extends StatelessWidget {
  final String label;
  final String value;

  const _ProgressItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _PendingDataCard extends StatelessWidget {
  final SyncState syncState;

  const _PendingDataCard({required this.syncState});

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
              'Pending Data',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _DataItem(
                    icon: Icons.access_time,
                    label: 'Shifts',
                    value: syncState.pendingShifts.toString(),
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DataItem(
                    icon: Icons.location_on,
                    label: 'GPS Points',
                    value: syncState.pendingGpsPoints.toString(),
                    color: Colors.orange,
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

class _DataItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _DataItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall,
                ),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
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

class _RetryInfoCard extends StatelessWidget {
  final SyncState syncState;

  const _RetryInfoCard({required this.syncState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: Colors.orange.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.refresh, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Retry Scheduled',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.orange,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Attempt ${syncState.consecutiveFailures + 1}',
              style: theme.textTheme.bodyMedium,
            ),
            if (syncState.nextRetryIn != null) ...[
              const SizedBox(height: 4),
              Text(
                'Next retry in ${_formatDuration(syncState.nextRetryIn!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }
}

class _StorageCard extends StatelessWidget {
  final StorageState storageState;
  final WidgetRef ref;

  const _StorageCard({required this.storageState, required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = storageState.metrics;

    final color = metrics.isCritical
        ? Colors.red
        : metrics.isWarning
            ? Colors.orange
            : Colors.green;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Local Storage',
                  style: theme.textTheme.titleSmall,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${metrics.usagePercent.toStringAsFixed(0)}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: metrics.usagePercent / 100,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              color: color,
              backgroundColor: color.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 8),
            Text(
              '${metrics.formattedUsed} of ${metrics.formattedTotal} used',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (storageState.breakdown != null) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              _StorageBreakdownRow(
                label: 'Shifts',
                value: storageState.breakdown!.formattedShifts,
                percent: storageState.breakdown!.shiftsPercent,
              ),
              _StorageBreakdownRow(
                label: 'GPS Points',
                value: storageState.breakdown!.formattedGpsPoints,
                percent: storageState.breakdown!.gpsPointsPercent,
              ),
              _StorageBreakdownRow(
                label: 'Logs',
                value: storageState.breakdown!.formattedLogs,
                percent: storageState.breakdown!.logsPercent,
              ),
            ],
            if (metrics.isWarning) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: storageState.isLoading
                    ? null
                    : () => ref.read(storageProvider.notifier).performCleanup(),
                child: storageState.isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Clean Up Storage'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StorageBreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final double percent;

  const _StorageBreakdownRow({
    required this.label,
    required this.value,
    required this.percent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall,
          ),
          Text(
            '$value (${percent.toStringAsFixed(0)}%)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionsSection extends StatelessWidget {
  final SyncState syncState;
  final WidgetRef ref;

  const _ActionsSection({
    required this.syncState,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (syncState.canSync || syncState.status == SyncStatus.error)
          Expanded(
            child: FilledButton.icon(
              onPressed: syncState.status == SyncStatus.syncing
                  ? null
                  : () {
                      ref.read(syncProvider.notifier).retrySync();
                    },
              icon: const Icon(Icons.sync),
              label: Text(
                syncState.status == SyncStatus.error
                    ? 'Retry Now'
                    : 'Sync Now',
              ),
            ),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            label: const Text('Close'),
          ),
        ),
      ],
    );
  }
}
