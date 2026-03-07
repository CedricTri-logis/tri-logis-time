import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/lunch_break_provider.dart';
import '../providers/shift_provider.dart';

class LunchBreakButton extends ConsumerWidget {
  const LunchBreakButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftState = ref.watch(shiftProvider);
    final lunchState = ref.watch(lunchBreakProvider);
    final hasActiveShift = shiftState.activeShift != null;

    if (!hasActiveShift) return const SizedBox.shrink();

    final isOnLunch = lunchState.isOnLunch;
    final isLoading = lunchState.isStarting || lunchState.isEnding;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: ElevatedButton.icon(
            onPressed: isLoading
                ? null
                : () {
                    if (isOnLunch) {
                      ref.read(lunchBreakProvider.notifier).endLunchBreak();
                    } else {
                      ref.read(lunchBreakProvider.notifier).startLunchBreak();
                    }
                  },
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    isOnLunch ? Icons.restaurant : Icons.restaurant_outlined,
                    size: 20,
                  ),
            label: Text(
              isOnLunch ? 'FIN PAUSE' : 'PAUSE DÎNER',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                fontSize: 14,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isOnLunch ? Colors.green.shade600 : Colors.orange.shade600,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              elevation: 3,
            ),
          ),
        ),
      ),
    );
  }
}
