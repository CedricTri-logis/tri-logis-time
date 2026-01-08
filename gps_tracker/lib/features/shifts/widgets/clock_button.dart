import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/shift_provider.dart';

/// Large clock-in/out button widget.
class ClockButton extends ConsumerWidget {
  final VoidCallback? onClockIn;
  final VoidCallback? onClockOut;

  const ClockButton({
    super.key,
    this.onClockIn,
    this.onClockOut,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftState = ref.watch(shiftProvider);
    final hasActiveShift = shiftState.activeShift != null;
    final isLoading = shiftState.isClockingIn || shiftState.isClockingOut;
    final theme = Theme.of(context);

    return SizedBox(
      width: 180,
      height: 180,
      child: ElevatedButton(
        onPressed: isLoading
            ? null
            : () {
                if (hasActiveShift) {
                  onClockOut?.call();
                } else {
                  onClockIn?.call();
                }
              },
        style: ElevatedButton.styleFrom(
          shape: const CircleBorder(),
          backgroundColor: hasActiveShift
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
          foregroundColor: hasActiveShift
              ? theme.colorScheme.onError
              : theme.colorScheme.onPrimary,
          elevation: 8,
          shadowColor: hasActiveShift
              ? theme.colorScheme.error.withValues(alpha: 0.4)
              : theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        child: isLoading
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    hasActiveShift ? Icons.stop : Icons.play_arrow,
                    size: 48,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasActiveShift ? 'Clock Out' : 'Clock In',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: hasActiveShift
                          ? theme.colorScheme.onError
                          : theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
