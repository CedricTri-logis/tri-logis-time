import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/theme.dart';
import '../providers/shift_provider.dart';

/// Large clock-in/out button widget.
class ClockButton extends ConsumerWidget {
  final VoidCallback? onClockIn;
  final VoidCallback? onClockOut;
  final bool isExternallyLoading;

  const ClockButton({
    super.key,
    this.onClockIn,
    this.onClockOut,
    this.isExternallyLoading = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftState = ref.watch(shiftProvider);
    final hasActiveShift = shiftState.activeShift != null;
    final isLoading =
        isExternallyLoading || shiftState.isClockingIn || shiftState.isClockingOut;
    final theme = Theme.of(context);

    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (hasActiveShift ? TriLogisColors.darkRed : TriLogisColors.red)
                .withValues(alpha: 0.3),
            blurRadius: 25,
            spreadRadius: 5,
          ),
        ],
      ),
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
              ? TriLogisColors.darkRed
              : TriLogisColors.red,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.all(32),
        ),
        child: isLoading
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasActiveShift ? Icons.timer_off_outlined : Icons.timer_outlined,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hasActiveShift ? 'TERMINER' : 'DÉBUTER',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasActiveShift ? 'Le Quart' : 'Un Quart',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
