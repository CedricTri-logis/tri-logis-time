import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/theme.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../providers/device_session_provider.dart';
import '../services/auth_rate_limiter.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/device_info_service.dart';
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
  bool _biometricAvailable = false;
  bool _biometricReady = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();

    // Show explanation if user was force-logged out by another device
    if (DeviceSessionNotifier.wasForceLoggedOut) {
      DeviceSessionNotifier.wasForceLoggedOut = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Session terminée : un autre appareil s\'est connecté à votre compte',
              ),
              duration: Duration(seconds: 6),
            ),
          );
        }
      });
    }
  }

  Future<void> _checkBiometric() async {
    final bio = ref.read(biometricServiceProvider);
    final available = await bio.isAvailable();
    final ready = await bio.hasCredentials();
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricReady = ready;
      });
    }
  }

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

      // Save credentials for biometric login on next launch
      if (_biometricAvailable) {
        final bio = ref.read(biometricServiceProvider);
        await bio.saveCredentials(
          email: _emailController.text.trim().toLowerCase(),
          password: _passwordController.text,
        );
      }

      // Sync device info (fire-and-forget)
      final client = ref.read(supabaseClientProvider);
      DeviceInfoService(client).syncDeviceInfo();

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

  Future<void> _handleBiometricSignIn() async {
    setState(() => _isLoading = true);

    try {
      final bio = ref.read(biometricServiceProvider);
      final credentials = await bio.authenticate();

      if (credentials == null) {
        // User cancelled or biometric failed
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final authService = ref.read(authServiceProvider);
      await authService.signIn(
        email: credentials.email,
        password: credentials.password,
      );

      // Sync device info (fire-and-forget)
      final client = ref.read(supabaseClientProvider);
      DeviceInfoService(client).syncDeviceInfo();
    } on AuthServiceException catch (e) {
      if (mounted) {
        // If saved password is wrong (user changed it), clear biometric
        final bio = ref.read(biometricServiceProvider);
        await bio.clearCredentials();
        setState(() => _biometricReady = false);
        ErrorSnackbar.show(
          context,
          '${e.message}. Veuillez vous connecter manuellement.',
        );
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

  String get _biometricLabel {
    if (Platform.isIOS) return 'Face ID';
    return 'Biométrie';
  }

  IconData get _biometricIcon {
    if (Platform.isIOS) return Icons.face;
    return Icons.fingerprint;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.white,
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
                  // Branded Logo
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Image.asset(
                        'assets/images/logo.png',
                        height: 100,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Title
                  Text(
                    'Pointage Employé',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: TriLogisColors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connectez-vous pour débuter votre quart',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Biometric quick login button
                  if (_biometricReady) ...[
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _handleBiometricSignIn,
                      icon: Icon(_biometricIcon, size: 24, color: TriLogisColors.gold),
                      label: Text(
                        'Connexion avec $_biometricLabel',
                        style: const TextStyle(color: TriLogisColors.black),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: TriLogisColors.gold),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey[300])),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'ou',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey[500],
                            ),
                          ),
                        ),
                        Expanded(child: Divider(color: Colors.grey[300])),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

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
