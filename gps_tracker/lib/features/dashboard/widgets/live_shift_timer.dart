import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/models/shift.dart';

/// Widget displaying a live-updating timer for the current shift.
///
/// Updates every second using timestamp-based calculation for accuracy.
/// Handles app lifecycle changes to prevent drift.
class LiveShiftTimer extends ConsumerStatefulWidget {
  /// The active shift to display timer for.
  final Shift shift;

  /// Optional text style override.
  final TextStyle? style;

  /// Whether to show hours even when zero.
  final bool showZeroHours;

  const LiveShiftTimer({
    super.key,
    required this.shift,
    this.style,
    this.showZeroHours = true,
  });

  @override
  ConsumerState<LiveShiftTimer> createState() => _LiveShiftTimerState();
}

class _LiveShiftTimerState extends ConsumerState<LiveShiftTimer>
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
  void didUpdateWidget(LiveShiftTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shift.id != widget.shift.id ||
        oldWidget.shift.clockedInAt != widget.shift.clockedInAt) {
      _recalculateElapsed();
    }
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
    setState(() {
      _elapsed = DateTime.now().difference(widget.shift.clockedInAt);
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (!widget.showZeroHours && hours == 0) {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final defaultStyle = theme.textTheme.displayMedium?.copyWith(
      fontWeight: FontWeight.bold,
      fontFeatures: [const FontFeature.tabularFigures()],
      letterSpacing: 2,
    );

    return Text(
      _formatDuration(_elapsed),
      style: widget.style ?? defaultStyle,
    );
  }
}

/// Compact version of the live timer for list items.
class CompactLiveTimer extends StatefulWidget {
  final DateTime startTime;
  final TextStyle? style;

  const CompactLiveTimer({
    super.key,
    required this.startTime,
    this.style,
  });

  @override
  State<CompactLiveTimer> createState() => _CompactLiveTimerState();
}

class _CompactLiveTimerState extends State<CompactLiveTimer> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _recalculate();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recalculate();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _recalculate() {
    setState(() {
      _elapsed = DateTime.now().difference(widget.startTime);
    });
  }

  String _formatCompact() {
    final hours = _elapsed.inHours;
    final minutes = _elapsed.inMinutes.remainder(60);
    if (hours == 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _formatCompact(),
      style: widget.style,
    );
  }
}
