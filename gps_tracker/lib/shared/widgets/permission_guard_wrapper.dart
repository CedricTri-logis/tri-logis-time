import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/permission_guard_provider.dart';

/// Wrapper that checks permission status before showing child.
/// Can be used to gate entire screens or sections based on permission status.
class PermissionGuardWrapper extends ConsumerWidget {
  /// The child to display when permissions are sufficient.
  final Widget child;

  /// Optional widget to show when permissions are insufficient.
  final Widget? fallback;

  /// Whether to only warn (true) or block (false) on insufficient permission.
  final bool warnOnly;

  const PermissionGuardWrapper({
    required this.child,
    this.fallback,
    this.warnOnly = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guardState = ref.watch(permissionGuardProvider);

    // Determine if we should block or warn
    final shouldBlock = !warnOnly && guardState.shouldBlockClockIn;
    final shouldWarn = warnOnly && guardState.shouldWarnOnClockIn;

    if (shouldBlock) {
      return fallback ?? _buildDefaultBlockedUI(context, ref);
    }

    if (shouldWarn) {
      return Stack(
        children: [
          child,
          _buildWarningOverlay(context),
        ],
      );
    }

    return child;
  }

  Widget _buildDefaultBlockedUI(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_off,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Permission de localisation requise',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Cette fonctionnalité nécessite la permission de localisation. '
              "Veuillez accorder l'accès à la localisation pour continuer.",
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await ref
                    .read(permissionGuardProvider.notifier)
                    .requestPermission();
              },
              icon: const Icon(Icons.location_on),
              label: const Text('Accorder la permission'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarningOverlay(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(12),
        color: Colors.orange.withValues(alpha: 0.9),
        child: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.white),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'La permission limitée peut affecter la fonctionnalité',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
