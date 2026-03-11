import 'package:flutter/material.dart';

import '../models/activity_type.dart';

/// Full-screen modal picker shown at clock-in. Returns selected [ActivityType].
class ActivityTypePicker extends StatelessWidget {
  const ActivityTypePicker({super.key});

  /// Shows the picker and returns the selected activity type, or null if dismissed.
  static Future<ActivityType?> show(BuildContext context) {
    return showModalBottomSheet<ActivityType>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const ActivityTypePicker(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: bottomPadding + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choisir le type d\'activité',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: 'Fermer',
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Activity type cards
            ...ActivityType.values.map(
              (type) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ActivityCard(
                  activityType: type,
                  onTap: () => Navigator.pop(context, type),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activityType,
    required this.onTap,
  });

  final ActivityType activityType;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 120,
          decoration: BoxDecoration(
            color: activityType.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(
                color: activityType.color,
                width: 4,
              ),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 20),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: activityType.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  activityType.icon,
                  color: activityType.color,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activityType.displayName,
                      style:
                          Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: activityType.color,
                              ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      activityType.description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.7),
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: activityType.color.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}
