import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/storage_provider.dart';

/// Banner showing storage warning when capacity is low.
class StorageWarningBanner extends ConsumerWidget {
  const StorageWarningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageState = ref.watch(storageProvider);

    if (!storageState.showWarning) {
      return const SizedBox.shrink();
    }

    final isCritical = storageState.isCritical;
    final color = isCritical ? Colors.red : Colors.orange;

    return Material(
      color: color.withValues(alpha: 0.1),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                isCritical ? Icons.warning : Icons.storage,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isCritical ? 'Storage Critical' : 'Storage Warning',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${storageState.usagePercent.toStringAsFixed(0)}% used '
                      '(${storageState.metrics.formattedUsed}/${storageState.metrics.formattedTotal})',
                      style: TextStyle(
                        color: color.withValues(alpha: 0.8),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (storageState.isLoading)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else ...[
                TextButton(
                  onPressed: () async {
                    await ref.read(storageProvider.notifier).performCleanup();
                  },
                  style: TextButton.styleFrom(foregroundColor: color),
                  child: const Text('Clean Up'),
                ),
                IconButton(
                  onPressed: () {
                    ref.read(storageProvider.notifier).dismissWarning();
                  },
                  icon: Icon(Icons.close, color: color, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact storage indicator for app bar.
class StorageIndicator extends ConsumerWidget {
  const StorageIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageState = ref.watch(storageProvider);
    final metrics = storageState.metrics;

    if (!metrics.isWarning) {
      return const SizedBox.shrink();
    }

    final color = metrics.isCritical ? Colors.red : Colors.orange;

    return Tooltip(
      message: '${metrics.usagePercent.toStringAsFixed(0)}% storage used',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storage, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              '${metrics.usagePercent.toStringAsFixed(0)}%',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
