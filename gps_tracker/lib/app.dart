import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/theme.dart';
import 'features/auth/providers/device_session_provider.dart';
import 'features/auth/screens/phone_registration_screen.dart';
import 'features/auth/screens/sign_in_screen.dart';
import 'features/home/home_screen.dart';
import 'shared/providers/supabase_provider.dart';
import 'features/auth/services/device_info_service.dart';
import 'shared/services/realtime_service.dart';

/// Grace period for skipping phone registration (7 days).
const _phoneSkipGraceDays = 7;
const _phoneSkipStorageKey = 'phone_registration_skipped_at';

/// Checks phone registration status, accounting for skip grace period.
/// Returns ({bool needsRegistration, bool canSkip}).
final _phoneRegistrationStatusProvider =
    FutureProvider.autoDispose<({bool needsRegistration, bool canSkip})>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return (needsRegistration: false, canSkip: false);

  // Check if phone is already registered
  try {
    final result = await client.rpc<bool>('check_phone_registered');
    if (result == true) {
      // Phone registered — clean up any leftover skip timestamp
      const storage = FlutterSecureStorage();
      await storage.delete(key: _phoneSkipStorageKey);
      return (needsRegistration: false, canSkip: false);
    }
  } catch (_) {
    // Fail-open: let the user through
    return (needsRegistration: false, canSkip: false);
  }

  // Phone not registered — check if grace period is active
  const storage = FlutterSecureStorage();
  final skippedAt = await storage.read(key: _phoneSkipStorageKey);

  if (skippedAt != null) {
    try {
      final skipDate = DateTime.parse(skippedAt);
      final daysSinceSkip = DateTime.now().difference(skipDate).inDays;
      if (daysSinceSkip < _phoneSkipGraceDays) {
        // Grace period still active — let through
        return (needsRegistration: false, canSkip: false);
      }
    } catch (_) {
      // Corrupted timestamp, treat as expired
    }
    // Grace period expired — must register, no more skipping
    return (needsRegistration: true, canSkip: false);
  }

  // Never skipped before — show registration with skip option
  return (needsRegistration: true, canSkip: true);
});

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
            // Keep Realtime subscriptions alive and subscribe for current user
            final realtimeService = ref.watch(realtimeServiceProvider);
            final userId = Supabase.instance.client.auth.currentUser?.id;
            if (userId != null) {
              realtimeService.subscribe(userId);
              DeviceInfoService(Supabase.instance.client).syncDeviceInfo();
            }
            return const _PhoneCheckGate();
          }
          return const SignInScreen();
        },
        loading: () => const _SplashScreen(),
        error: (_, __) => const SignInScreen(),
      ),
    );
  }
}

/// Gate that checks phone registration before showing HomeScreen.
class _PhoneCheckGate extends ConsumerWidget {
  const _PhoneCheckGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(_phoneRegistrationStatusProvider);

    return status.when(
      data: (s) {
        if (!s.needsRegistration) {
          return const HomeScreen();
        }
        return _PhoneRegistrationGate(canSkip: s.canSkip);
      },
      loading: () => const _SplashScreen(),
      // Fail-open on error
      error: (_, __) => const HomeScreen(),
    );
  }
}

/// Wraps PhoneRegistrationScreen and handles its result.
class _PhoneRegistrationGate extends ConsumerStatefulWidget {
  final bool canSkip;
  const _PhoneRegistrationGate({required this.canSkip});

  @override
  ConsumerState<_PhoneRegistrationGate> createState() =>
      _PhoneRegistrationGateState();
}

class _PhoneRegistrationGateState
    extends ConsumerState<_PhoneRegistrationGate> {
  bool _completed = false;

  void _onCompleted() {
    setState(() => _completed = true);
    ref.invalidate(_phoneRegistrationStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (_completed) {
      return const HomeScreen();
    }

    return PhoneRegistrationScreen(
      canSkip: widget.canSkip,
      onCompleted: _onCompleted,
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
