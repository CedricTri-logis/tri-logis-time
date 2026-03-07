import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// Wraps a child widget with a Listener that fires a soft GPS health nudge
/// on any pointer-down event.
class GpsHealthListener extends ConsumerWidget {
  final Widget child;

  const GpsHealthListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        nudgeGpsFromWidget(ref, source: 'dashboard_interaction');
      },
      child: child,
    );
  }
}
