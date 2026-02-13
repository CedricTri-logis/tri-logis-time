import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/shift_provider.dart';

/// Widget displaying the elapsed shift time with real-time updates.
class ShiftTimer extends ConsumerStatefulWidget {
  const ShiftTimer({super.key});

  @override
  ConsumerState<ShiftTimer> createState() => _ShiftTimerState();
}

class _ShiftTimerState extends ConsumerState<ShiftTimer>
    with WidgetsBindingObserver {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recalculateElapsed();
    }
  }

  void _startTimer() {
    _recalculateElapsed();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recalculateElapsed();
    });
  }

  void _recalculateElapsed() {
    final activeShift = ref.read(shiftProvider).activeShift;
    if (activeShift != null) {
      setState(() {
        _elapsed = DateTime.now().difference(activeShift.clockedInAt);
      });
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final shiftState = ref.watch(shiftProvider);
    final activeShift = shiftState.activeShift;
    final theme = Theme.of(context);

    if (activeShift == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          children: [
            Text(
              'Durée du quart',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _formatDuration(_elapsed),
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                fontFeatures: [const FontFeature.tabularFigures()],
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
