import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tracking/providers/tracking_provider.dart';
import '../models/shift.dart';
import '../models/shift_enums.dart';
import '../providers/lunch_break_provider.dart';
import '../providers/shift_provider.dart';
import '../providers/sync_provider.dart';
import 'sync_detail_sheet.dart';

/// Minimal card showing active shift: start time + live elapsed timer.
/// Combined sync/tracking badge opens detail sheet on tap.
class ShiftStatusCard extends ConsumerStatefulWidget {
  const ShiftStatusCard({super.key});

  @override
  ConsumerState<ShiftStatusCard> createState() => _ShiftStatusCardState();
}

class _ShiftStatusCardState extends ConsumerState<ShiftStatusCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatElapsed(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    final seconds = d.inSeconds.remainder(60);
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final shiftState = ref.watch(shiftProvider);
    final activeShift = shiftState.activeShift;
    final theme = Theme.of(context);

    if (activeShift == null) {
      return _buildReadyCard(theme);
    }

    return _buildActiveShiftCard(theme, activeShift);
  }

  Widget _buildReadyCard(ThemeData theme) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.access_time,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Prêt à commencer',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Appuyez sur le bouton pour débuter',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveShiftCard(ThemeData theme, Shift activeShift) {
    final localTime = activeShift.clockedInAt.toLocal();
    final elapsed = DateTime.now().difference(localTime);
    final syncState = ref.watch(syncProvider);
    final trackingState = ref.watch(trackingProvider);

    // Calculate work time (elapsed minus lunch)
    final lunchState = ref.watch(lunchBreakProvider);
    final breaks = ref.watch(lunchBreaksForShiftProvider(activeShift.id)).valueOrNull ?? [];
    Duration totalLunch = Duration.zero;
    for (final lb in breaks) {
      if (lb.endedAt != null) {
        totalLunch += lb.endedAt!.difference(lb.startedAt);
      }
    }
    if (lunchState.activeLunchBreak != null) {
      totalLunch += DateTime.now().toUtc().difference(lunchState.activeLunchBreak!.startedAt);
    }
    final workTime = elapsed - totalLunch;
    final isOnLunch = lunchState.isOnLunch;
    final pointsCaptured = trackingState.pointsCaptured;

    // Determine badge color from sync status
    final badgeColor = switch (syncState.status) {
      SyncStatus.synced => Colors.green,
      SyncStatus.pending => Colors.orange,
      SyncStatus.syncing => Colors.blue,
      SyncStatus.error => Colors.red,
    };

    final badgeIcon = switch (syncState.status) {
      SyncStatus.synced => Icons.cloud_done,
      SyncStatus.pending => Icons.cloud_upload,
      SyncStatus.syncing => Icons.cloud_sync,
      SyncStatus.error => Icons.cloud_off,
    };

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Top row: status + combined badge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Status dot + label (orange when on lunch)
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isOnLunch ? Colors.orange : Colors.green,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isOnLunch ? Colors.orange : Colors.green)
                                .withValues(alpha: 0.4),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isOnLunch ? 'Pause dîner' : 'En cours',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isOnLunch ? Colors.orange : Colors.green,
                      ),
                    ),
                  ],
                ),
                // Combined badge: sync icon + point count — tappable
                GestureDetector(
                  onTap: () => SyncDetailSheet.show(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: badgeColor.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (syncState.status == SyncStatus.syncing)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: badgeColor,
                            ),
                          )
                        else
                          Icon(badgeIcon, size: 14, color: badgeColor),
                        const SizedBox(width: 5),
                        Text(
                          '$pointsCaptured',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: badgeColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Bottom row: start time + elapsed time
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Début',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(localTime),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Temps de travail',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatElapsed(workTime < Duration.zero ? Duration.zero : workTime),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isOnLunch
                              ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
                              : theme.colorScheme.primary,
                        ),
                      ),
                    ],
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
