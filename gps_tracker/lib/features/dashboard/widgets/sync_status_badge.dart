import 'package:flutter/material.dart';

import '../../shifts/providers/sync_provider.dart';
import '../../shifts/models/shift_enums.dart';

/// Badge displaying sync status with pending count and error handling.
///
/// Shows:
/// - Synced: Green checkmark when all data is synced
/// - Pending: Yellow indicator with pending count
/// - Syncing: Blue animated progress
/// - Error: Red with retry action
class SyncStatusBadge extends StatelessWidget {
  final SyncState syncState;

  /// Optional callback for retry action on error.
  final VoidCallback? onRetry;

  /// Whether to show detailed information.
  final bool showDetails;

  const SyncStatusBadge({
    super.key,
    required this.syncState,
    this.onRetry,
    this.showDetails = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Don't show anything if synced and no pending data
    if (syncState.status == SyncStatus.synced && !syncState.hasPendingData) {
      if (!showDetails) return const SizedBox.shrink();
      return _SyncedBadge();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _backgroundColor(theme),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _borderColor(theme),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(theme),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: _textColor(theme),
                  ),
                ),
                if (showDetails && _detailText != null)
                  Text(
                    _detailText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _textColor(theme).withOpacity(0.8),
                    ),
                  ),
              ],
            ),
          ),
          if (syncState.status == SyncStatus.error && onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 32),
              ),
              child: Text(
                'Retry',
                style: TextStyle(color: _textColor(theme)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIcon(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Icon(Icons.cloud_done, color: _iconColor(theme), size: 20);
      case SyncStatus.pending:
        return Icon(Icons.cloud_upload, color: _iconColor(theme), size: 20);
      case SyncStatus.syncing:
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: _iconColor(theme),
          ),
        );
      case SyncStatus.error:
        return Icon(Icons.cloud_off, color: _iconColor(theme), size: 20);
    }
  }

  Color _backgroundColor(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Colors.green.withOpacity(0.1);
      case SyncStatus.pending:
        return Colors.orange.withOpacity(0.1);
      case SyncStatus.syncing:
        return Colors.blue.withOpacity(0.1);
      case SyncStatus.error:
        return theme.colorScheme.errorContainer;
    }
  }

  Color _borderColor(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Colors.green.withOpacity(0.3);
      case SyncStatus.pending:
        return Colors.orange.withOpacity(0.3);
      case SyncStatus.syncing:
        return Colors.blue.withOpacity(0.3);
      case SyncStatus.error:
        return theme.colorScheme.error.withOpacity(0.3);
    }
  }

  Color _iconColor(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Colors.green;
      case SyncStatus.pending:
        return Colors.orange;
      case SyncStatus.syncing:
        return Colors.blue;
      case SyncStatus.error:
        return theme.colorScheme.error;
    }
  }

  Color _textColor(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Colors.green.shade700;
      case SyncStatus.pending:
        return Colors.orange.shade700;
      case SyncStatus.syncing:
        return Colors.blue.shade700;
      case SyncStatus.error:
        return theme.colorScheme.onErrorContainer;
    }
  }

  String get _statusText {
    switch (syncState.status) {
      case SyncStatus.synced:
        return 'All synced';
      case SyncStatus.pending:
        return 'Pending sync';
      case SyncStatus.syncing:
        return 'Syncing...';
      case SyncStatus.error:
        return 'Sync error';
    }
  }

  String? get _detailText {
    switch (syncState.status) {
      case SyncStatus.synced:
        if (syncState.lastSyncTime != null) {
          return 'Last synced ${_formatRelativeTime(syncState.lastSyncTime!)}';
        }
        return null;
      case SyncStatus.pending:
        final total = syncState.totalPending;
        if (total == 0) return null;
        return '$total item${total == 1 ? '' : 's'} waiting';
      case SyncStatus.syncing:
        if (syncState.progress != null) {
          final progress = syncState.progress!;
          return '${progress.syncedShifts}/${progress.totalShifts} shifts';
        }
        return null;
      case SyncStatus.error:
        if (syncState.nextRetryIn != null) {
          final seconds = syncState.nextRetryIn!.inSeconds;
          return 'Retrying in ${seconds}s';
        }
        return syncState.lastError ?? 'Failed to sync';
    }
  }

  String _formatRelativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _SyncedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_done, color: Colors.green, size: 20),
          const SizedBox(width: 8),
          Text(
            'All synced',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.green.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact version for app bar or small spaces.
class SyncStatusIcon extends StatelessWidget {
  final SyncState syncState;
  final VoidCallback? onTap;

  const SyncStatusIcon({
    super.key,
    required this.syncState,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Don't show anything if synced
    if (syncState.status == SyncStatus.synced && !syncState.hasPendingData) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: onTap,
      child: Badge(
        isLabelVisible: syncState.hasPendingData,
        label: Text('${syncState.totalPending}'),
        child: Icon(
          _iconData,
          color: _iconColor(theme),
        ),
      ),
    );
  }

  IconData get _iconData {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Icons.cloud_done;
      case SyncStatus.pending:
        return Icons.cloud_upload;
      case SyncStatus.syncing:
        return Icons.sync;
      case SyncStatus.error:
        return Icons.cloud_off;
    }
  }

  Color _iconColor(ThemeData theme) {
    switch (syncState.status) {
      case SyncStatus.synced:
        return Colors.green;
      case SyncStatus.pending:
        return Colors.orange;
      case SyncStatus.syncing:
        return Colors.blue;
      case SyncStatus.error:
        return theme.colorScheme.error;
    }
  }
}
