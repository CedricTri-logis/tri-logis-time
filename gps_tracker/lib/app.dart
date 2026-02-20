import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/theme.dart';
import 'features/auth/providers/device_session_provider.dart';
import 'features/auth/screens/sign_in_screen.dart';
import 'features/home/home_screen.dart';
import 'shared/providers/supabase_provider.dart';

class GpsTrackerApp extends ConsumerWidget {
  const GpsTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateChangesProvider);

    return MaterialApp(
      title: 'Tri-Logis Time',
      debugShowCheckedModeBanner: false,
      theme: TriLogisTheme.lightTheme,
      darkTheme: TriLogisTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: authState.when(
        data: (state) {
          if (state.session != null) {
            // Keep device session monitor alive while authenticated
            ref.watch(deviceSessionProvider);
            return const HomeScreen();
          }
          return const SignInScreen();
        },
        loading: () => const _SplashScreen(),
        error: (_, __) => const SignInScreen(),
      ),
    );
  }
}

/// Simple splash screen shown while checking auth state
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_on,
              size: 80,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
