import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_tracker/features/tracking/models/permission_guard_state.dart';
import 'package:gps_tracker/features/tracking/providers/permission_guard_provider.dart';
import 'package:gps_tracker/features/tracking/widgets/clock_button_settings_warning.dart';

Widget _wrap(Widget child, {PermissionGuardState? state}) {
  return ProviderScope(
    overrides: state == null
        ? []
        : [
            permissionGuardProvider.overrideWith(
              (ref) => _FakeNotifier(state),
            ),
          ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

class _FakeNotifier extends PermissionGuardNotifier {
  _FakeNotifier(PermissionGuardState s) : super() {
    // ignore: invalid_use_of_protected_member
    state = s;
  }
}

void main() {
  testWidgets('shows nothing when battery optimization is disabled (ok)',
      (tester) async {
    final goodState = PermissionGuardState.initial().copyWith(
      isBatteryOptimizationDisabled: true,
      isAppStandbyRestricted: false,
    );
    await tester.pumpWidget(
        _wrap(const ClockButtonSettingsWarning(), state: goodState));
    expect(find.text('Configuration requise'), findsNothing);
  });

  testWidgets('does not throw when rendered on non-Android test env',
      (tester) async {
    final badState = PermissionGuardState.initial().copyWith(
      isBatteryOptimizationDisabled: false,
    );
    await tester.pumpWidget(
        _wrap(const ClockButtonSettingsWarning(), state: badState));
    // On non-Android test env, widget renders SizedBox.shrink() — no throw
    expect(tester.takeException(), isNull);
  });
}
