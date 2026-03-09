import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/providers/shift_provider.dart';
import '../services/gps_health_guard.dart';
import 'tracking_provider.dart';

/// Singleton provider for the GPS health guard.
final gpsHealthGuardProvider = Provider<GpsHealthGuard>((ref) {
  return GpsHealthGuard();
});

/// Hard-gate health check from a provider context (Ref).
Future<HealthCheckResult> ensureGpsAlive(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  return guard.ensureAlive(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}

/// Soft nudge from a provider context (Ref).
void nudgeGps(Ref ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  guard.nudge(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}

/// Soft nudge from a widget context (WidgetRef).
void nudgeGpsFromWidget(WidgetRef ref, {required String source}) {
  final guard = ref.read(gpsHealthGuardProvider);
  final shiftState = ref.read(shiftProvider);
  final shift = shiftState.activeShift;
  final trackingNotifier = ref.read(trackingProvider.notifier);

  guard.nudge(
    source: source,
    hasActiveShift: shift != null,
    shiftId: shift?.id,
    startTrackingCallback: () => trackingNotifier.startTracking(),
  );
}
