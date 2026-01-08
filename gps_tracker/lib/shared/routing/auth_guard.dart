import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/screens/sign_in_screen.dart';
import '../providers/supabase_provider.dart';

/// Widget that protects routes from unauthenticated access
///
/// Redirects to SignInScreen if user is not authenticated.
/// Shows a loading indicator while checking auth state.
class AuthGuard extends ConsumerWidget {
  /// The child widget to show when authenticated
  final Widget child;

  const AuthGuard({
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);

    if (!isAuthenticated) {
      // Redirect to sign in screen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pushAndRemoveUntil<void>(
          MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
          (route) => false,
        );
      });
      return const SizedBox.shrink();
    }

    return child;
  }
}

/// A wrapper that includes auth guard functionality
///
/// Use this when you need to protect a route with authentication
/// and want to show a loading state while checking.
class AuthGuardedRoute extends ConsumerWidget {
  /// Builder function that returns the protected content
  final Widget Function(BuildContext context, WidgetRef ref) builder;

  /// Widget to show while loading auth state
  final Widget? loadingWidget;

  const AuthGuardedRoute({
    required this.builder,
    this.loadingWidget,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateChangesProvider);

    return authState.when(
      data: (state) {
        if (state.session == null) {
          // Not authenticated - redirect
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).pushAndRemoveUntil<void>(
              MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
              (route) => false,
            );
          });
          return const SizedBox.shrink();
        }
        return builder(context, ref);
      },
      loading: () => loadingWidget ?? const _DefaultLoadingWidget(),
      error: (_, __) {
        // On error, redirect to sign in
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.of(context).pushAndRemoveUntil<void>(
            MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
            (route) => false,
          );
        });
        return const SizedBox.shrink();
      },
    );
  }
}

class _DefaultLoadingWidget extends StatelessWidget {
  const _DefaultLoadingWidget();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
