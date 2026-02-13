import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../services/auth_rate_limiter.dart';
import '../services/auth_service.dart';
import '../services/validators.dart';
import '../widgets/auth_button.dart';
import '../widgets/auth_form_field.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

/// Sign in screen for employee authentication
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _rateLimiter = AuthRateLimiter();

  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn() async {
    // Validate form
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Check rate limit
    if (!_rateLimiter.canAttempt()) {
      final remaining = _rateLimiter.getRemainingLockout();
      if (remaining != null && mounted) {
        ErrorSnackbar.show(
          context,
          'Trop de tentatives. Réessayez dans ${AuthRateLimiter.formatDuration(remaining)}',
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    _rateLimiter.recordAttempt();

    try {
      final authService = ref.read(authServiceProvider);
      await authService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );

      // Success - navigation handled by auth state listener in app.dart
      _rateLimiter.reset();
    } on AuthServiceException catch (e) {
      if (mounted) {
        ErrorSnackbar.show(context, e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _navigateToSignUp() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SignUpScreen()),
    );
  }

  void _navigateToForgotPassword() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ForgotPasswordScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // App logo/icon
                  Icon(
                    Icons.location_on,
                    size: 80,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),

                  // Title
                  Text(
                    'Bon retour',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connectez-vous pour continuer',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Email field
                  AuthFormField.email(
                    controller: _emailController,
                    focusNode: _emailFocusNode,
                    validator: EmailValidator.validate,
                    enabled: !_isLoading,
                    onSubmitted: () => _passwordFocusNode.requestFocus(),
                  ),
                  const SizedBox(height: 16),

                  // Password field
                  AuthFormField.password(
                    controller: _passwordController,
                    focusNode: _passwordFocusNode,
                    obscureText: _obscurePassword,
                    onToggleVisibility: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Le mot de passe est requis';
                      }
                      return null;
                    },
                    enabled: !_isLoading,
                    onSubmitted: _handleSignIn,
                  ),
                  const SizedBox(height: 8),

                  // Forgot password link
                  Align(
                    alignment: Alignment.centerRight,
                    child: AuthTextButton(
                      text: 'Mot de passe oublié?',
                      onPressed: _isLoading ? null : _navigateToForgotPassword,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Sign in button
                  AuthButton(
                    text: 'Connexion',
                    loadingText: 'Connexion en cours...',
                    isLoading: _isLoading,
                    onPressed: _handleSignIn,
                  ),
                  const SizedBox(height: 24),

                  // Sign up link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Pas de compte? ",
                        style: theme.textTheme.bodyMedium,
                      ),
                      AuthTextButton(
                        text: 'Créer un compte',
                        onPressed: _isLoading ? null : _navigateToSignUp,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
