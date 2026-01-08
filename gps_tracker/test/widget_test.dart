// GPS Tracker basic widget test.
//
// Tests that the app starts and shows the welcome screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_tracker/app.dart';

void main() {
  testWidgets('App shows welcome screen with app name', (
    WidgetTester tester,
  ) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const GpsTrackerApp());

    // Verify that the welcome screen is displayed with the app name.
    expect(find.text('GPS Clock-In Tracker'), findsOneWidget);

    // Verify setup confirmation message is shown.
    expect(
      find.text('Setup Complete! App is ready for development.'),
      findsOneWidget,
    );

    // Verify the tagline is displayed.
    expect(
      find.text('Track your work shifts with GPS verification'),
      findsOneWidget,
    );
  });
}
