import 'package:flutter/material.dart';

import '../models/activity_type.dart';

/// Result returned by SessionStartSheet.
class SessionStartResult {
  final SessionStartAction action;
  final ActivityType? activityType;

  const SessionStartResult(this.action, [this.activityType]);
}

enum SessionStartAction {
  /// Open QR scanner (ménage court terme)
  qrScan,
  /// Open building picker (ménage long terme or entretien)
  buildingPicker,
  /// Start admin session directly
  confirmAdmin,
  /// User wants to change activity type — show full picker
  changeType,
}

/// Modal bottom sheet shown when tapping "Aucune session active".
///
/// If lastActivityType exists, shows default options for that type.
/// Otherwise returns [SessionStartAction.changeType] to trigger full picker.
class SessionStartSheet extends StatelessWidget {
  final ActivityType defaultType;

  const SessionStartSheet({required this.defaultType, super.key});

  /// Show the sheet. Returns null if dismissed.
  static Future<SessionStartResult?> show(
    BuildContext context,
    ActivityType defaultType,
  ) {
    return showModalBottomSheet<SessionStartResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SessionStartSheet(defaultType: defaultType),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final color = defaultType.color;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: bottomPadding + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(defaultType.icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nouvelle session — ${defaultType.displayName}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Options based on activity type
            ..._buildOptions(context, color),

            // Divider
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),

            // Change activity type
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  const SessionStartResult(SessionStartAction.changeType),
                ),
                icon: const Icon(Icons.swap_horiz, size: 20),
                label: const Text("Changer d'activité"),
                style: TextButton.styleFrom(foregroundColor: Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOptions(BuildContext context, Color color) {
    switch (defaultType) {
      case ActivityType.cleaning:
        return [
          _OptionTile(
            icon: Icons.qr_code_scanner,
            label: 'Scanner un code QR',
            subtitle: 'Court terme — studios',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.qrScan),
            ),
          ),
          const SizedBox(height: 10),
          _OptionTile(
            icon: Icons.apartment,
            label: 'Choisir un immeuble',
            subtitle: 'Long terme — immeubles / appartements',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.buildingPicker),
            ),
          ),
        ];
      case ActivityType.maintenance:
        return [
          _OptionTile(
            icon: Icons.apartment,
            label: 'Choisir un immeuble',
            subtitle: 'Bâtiment ou appartement',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.buildingPicker),
            ),
          ),
        ];
      case ActivityType.admin:
        return [
          _OptionTile(
            icon: Icons.business_center,
            label: 'Commencer une session Administration',
            subtitle: 'Aucun lieu requis',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.confirmAdmin),
            ),
          ),
        ];
    }
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
