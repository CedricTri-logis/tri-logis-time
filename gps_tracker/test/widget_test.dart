// GPS Tracker basic widget test.
//
// Tests that the app starts and shows the sign-in screen when unauthenticated.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gps_tracker/features/auth/screens/sign_in_screen.dart';

void main() {
  testWidgets('Sign in screen shows welcome message and form', (
    WidgetTester tester,
  ) async {
    // Build the SignInScreen wrapped in required providers
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SignInScreen(),
        ),
      ),
    );

    // Allow any animations to settle
    await tester.pumpAndSettle();

    // Verify that the welcome message is displayed
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Sign in to continue'), findsOneWidget);

    // Verify the sign-in button is present
    expect(find.text('Sign In'), findsOneWidget);

    // Verify navigation links are present
    expect(find.text('Forgot Password?'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
  });
}
