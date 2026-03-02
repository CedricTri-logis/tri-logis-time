import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_tracker/features/tracking/screens/battery_health_screen.dart';

void main() {
  testWidgets('BatteryHealthScreen renders without error', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: BatteryHealthScreen(),
        ),
      ),
    );
    // Initial frame — FutureBuilder shows loading
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
