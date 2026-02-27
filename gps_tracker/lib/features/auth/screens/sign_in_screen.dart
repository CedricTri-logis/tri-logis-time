import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/theme.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../providers/app_lock_provider.dart';
import '../providers/device_session_provider.dart';
import '../services/auth_rate_limiter.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/device_info_service.dart';
import '../services/validators.dart';
import '../../../shared/services/session_backup_service.dart';
import '../widgets/auth_button.dart';
import '../widgets/auth_form_field.dart';
import '../widgets/otp_input_field.dart';
import '../widgets/otp_resend_button.dart';
import '../widgets/phone_form_field.dart';
import 'forgot_password_screen.dart';

/// Sign-in modes for the state machine
enum SignInMode { phone, otp, email }

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
  final _phoneController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _phoneFocusNode = FocusNode();
  final _otpKey = GlobalKey<OtpInputFieldState>();
  final _rateLimiter = AuthRateLimiter();

  SignInMode _mode = SignInMode.phone;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _biometricAvailable = false;
  bool _biometricReady = false;
  String _normalizedPhone = '';

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
                'Session terminee : un autre appareil s\'est connecte a votre compte',
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
    _phoneController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  /// Extract raw digits from the formatted phone field
  String get _rawDigits =>
      _phoneController.text.replaceAll(RegExp(r'[^\d]'), '');

  // ── SMS OTP Flow ──

  Future<void> _handleSendOtp() async {
    final error = PhoneValidator.validate(_rawDigits);
    if (error != null) {
      ErrorSnackbar.show(context, error);
      return;
    }

    final normalized = PhoneValidator.normalizeToE164(_rawDigits);
    if (normalized == null) {
      ErrorSnackbar.show(
        context,
        'Entrez un numero de telephone canadien valide (10 chiffres)',
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);

      // Check if the phone is registered before sending OTP
      // Prevents creation of @phone.local phantom accounts
      final exists = await authService.checkPhoneExists(phone: normalized);
      if (!exists) {
        if (mounted) {
          setState(() => _isLoading = false);
          ErrorSnackbar.show(
            context,
            'Aucun compte associe a ce numero. Contactez votre superviseur.',
          );
        }
        return;
      }

      await authService.sendOtp(phone: normalized);

      _normalizedPhone = normalized;
      if (mounted) {
        setState(() {
          _mode = SignInMode.otp;
          _isLoading = false;
        });
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ErrorSnackbar.show(context, e.message);
      }
    }
  }

  Future<void> _handleVerifyOtp(String code) async {
    // Guard against double-submission
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);
      final response = await authService.verifyOtp(
        phone: _normalizedPhone,
        token: code,
      );

      // Clear app lock so navigation proceeds (lock may be set from a
      // previous biometric "sign-out" that kept the session alive).
      ref.read(appLockProvider.notifier).state = false;

      // Save tokens for biometric login (with phone for OTP fallback)
      if (response.session != null && _biometricAvailable) {
        final bio = ref.read(biometricServiceProvider);
        await bio.saveSessionTokens(
          accessToken: response.session!.accessToken,
          refreshToken: response.session!.refreshToken ?? '',
          phone: _normalizedPhone,
        );
      }

      // Sync device info (fire-and-forget)
      final client = ref.read(supabaseClientProvider);
      DeviceInfoService(client).syncDeviceInfo();

      _rateLimiter.reset();
      // Navigation handled by auth state listener in app.dart
    } on AuthServiceException catch (e) {
      if (mounted) {
        _otpKey.currentState?.clear();
        ErrorSnackbar.show(context, e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleResendOtp() async {
    try {
      final authService = ref.read(authServiceProvider);
      await authService.sendOtp(phone: _normalizedPhone);
      if (mounted) {
        ErrorSnackbar.showSuccess(context, 'Nouveau code envoye');
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        ErrorSnackbar.show(context, e.message);
      }
    }
  }

  // ── Email+Password Flow ──

  Future<void> _handleEmailSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_rateLimiter.canAttempt()) {
      final remaining = _rateLimiter.getRemainingLockout();
      if (remaining != null && mounted) {
        ErrorSnackbar.show(
          context,
          'Trop de tentatives. Reessayez dans ${AuthRateLimiter.formatDuration(remaining)}',
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    _rateLimiter.recordAttempt();

    try {
      final authService = ref.read(authServiceProvider);
      final response = await authService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );

      // Save tokens for biometric login (fetch phone from user metadata for OTP fallback)
      if (response.session != null && _biometricAvailable) {
        final bio = ref.read(biometricServiceProvider);
        final userPhone = response.user?.phone;
        await bio.saveSessionTokens(
          accessToken: response.session!.accessToken,
          refreshToken: response.session!.refreshToken!,
          phone: (userPhone != null && userPhone.isNotEmpty) ? userPhone : null,
        );
      }

      // Sync device info (fire-and-forget)
      final client = ref.read(supabaseClientProvider);
      DeviceInfoService(client).syncDeviceInfo();

      _rateLimiter.reset();
      // Navigation handled by auth state listener in app.dart
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

  // ── Biometric Flow ──

  Future<void> _handleBiometricSignIn() async {
    // Fast path: app is locked (session still alive), just unlock with biometric
    final isLocked = ref.read(appLockProvider);
    if (isLocked) {
      setState(() => _isLoading = true);
      try {
        final bio = ref.read(biometricServiceProvider);
        final authenticated = await bio.authenticateOnly();
        if (!authenticated) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }

        // Unlock the app
        ref.read(appLockProvider.notifier).state = false;

        // If session is still alive, app.dart routes to HomeScreen automatically
        final client = ref.read(supabaseClientProvider);
        if (client.auth.currentSession != null) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }

        // Session died while locked → fall through to existing token restore flow
      } catch (_) {
        // Fall through to normal biometric flow
      }
      if (mounted) setState(() => _isLoading = false);
    }

    setState(() => _isLoading = true);

    try {
      final bio = ref.read(biometricServiceProvider);
      final authService = ref.read(authServiceProvider);

      // Try new token-based auth first
      final tokens = await bio.authenticate();

      if (tokens != null) {
        // Token-based biometric login
        try {
          final response = await authService.restoreSession(
            refreshToken: tokens.refreshToken,
          );

          // Update stored tokens with fresh ones
          if (response.session != null) {
            await bio.saveSessionTokens(
              accessToken: response.session!.accessToken,
              refreshToken: response.session!.refreshToken!,
            );
          }

          // Sync device info (fire-and-forget)
          final client = ref.read(supabaseClientProvider);
          DeviceInfoService(client).syncDeviceInfo();
          return;
        } on AuthServiceException {
          // Tokens expired, fall through to OTP fallback or legacy
        }
      }

      // Ensure biometric was authenticated (either from token flow or prompt now)
      final biometricAuthenticated =
          tokens != null || await bio.authenticateOnly();
      if (!biometricAuthenticated) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // Try legacy credential migration
      final legacyCredentials = await bio.getLegacyCredentials();
      if (legacyCredentials != null) {
        final response = await authService.signIn(
          email: legacyCredentials.email,
          password: legacyCredentials.password,
        );

        if (response.session != null) {
          final userPhone = response.user?.phone;
          await bio.saveSessionTokens(
            accessToken: response.session!.accessToken,
            refreshToken: response.session!.refreshToken!,
            phone: (userPhone != null && userPhone.isNotEmpty)
                ? userPhone
                : null,
          );
        }

        // Sync device info (fire-and-forget)
        final client = ref.read(supabaseClientProvider);
        DeviceInfoService(client).syncDeviceInfo();
        return;
      }

      // Fallback: use saved phone to re-authenticate via OTP.
      // Instead of a dialog, switch to the full-screen OTP mode
      // which already has proper layout for the 6 digit boxes.
      final savedPhone = await bio.getSavedPhone();
      if (savedPhone != null && mounted) {
        try {
          await authService.sendOtp(phone: savedPhone);
          _normalizedPhone = savedPhone;
          setState(() {
            _mode = SignInMode.otp;
            _isLoading = false;
          });
          ErrorSnackbar.show(
            context,
            'Session expiree. Un code a ete envoye au ${PhoneValidator.formatForDisplay(savedPhone)}',
          );
        } on AuthServiceException {
          // OTP send failed — let user sign in manually
          setState(() => _isLoading = false);
          ErrorSnackbar.show(context, 'Session expiree. Reconnectez-vous.');
        }
        return;
      }

      // No phone saved and no legacy credentials — clear and inform user
      await bio.clearCredentials();
      await SessionBackupService.clear();
      if (mounted) {
        setState(() => _biometricReady = false);
        ErrorSnackbar.show(context, 'Session expiree. Reconnectez-vous.');
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        final bio = ref.read(biometricServiceProvider);
        await bio.clearCredentials();
        await SessionBackupService.clear();
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

  // ── Navigation ──

  void _navigateToForgotPassword() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ForgotPasswordScreen()),
    );
  }

  String get _biometricLabel {
    if (Platform.isIOS) return 'Face ID';
    return 'Biometrie';
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
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
                  'Pointage Employe',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: TriLogisColors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Connectez-vous pour debuter votre quart',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Mode-specific content
                if (_mode == SignInMode.phone) _buildPhoneMode(theme),
                if (_mode == SignInMode.otp) _buildOtpMode(theme),
                if (_mode == SignInMode.email) _buildEmailMode(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Phone Mode ──

  Widget _buildPhoneMode(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Biometric quick login
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

        // Phone number field
        PhoneFormField(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          enabled: !_isLoading,
          onSubmitted: _handleSendOtp,
        ),
        const SizedBox(height: 24),

        // Send code button
        AuthButton(
          text: 'Envoyer le code',
          loadingText: 'Envoi en cours...',
          isLoading: _isLoading,
          onPressed: _handleSendOtp,
        ),
        const SizedBox(height: 24),

        // Switch to email
        Center(
          child: AuthTextButton(
            text: 'Connexion par courriel',
            onPressed: _isLoading
                ? null
                : () => setState(() => _mode = SignInMode.email),
          ),
        ),
      ],
    );
  }

  // ── OTP Mode ──

  Widget _buildOtpMode(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Verification',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: TriLogisColors.black,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Code envoye au ${PhoneValidator.formatForDisplay(_normalizedPhone)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        OtpInputField(
          key: _otpKey,
          onCompleted: _handleVerifyOtp,
          enabled: !_isLoading,
        ),
        const SizedBox(height: 16),

        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else ...[
          Center(
            child: OtpResendButton(onResend: _handleResendOtp),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () {
                setState(() => _mode = SignInMode.phone);
              },
              child: const Text('Changer de numero'),
            ),
          ),
        ],
      ],
    );
  }

  // ── Email Mode (fallback) ──

  Widget _buildEmailMode(ThemeData theme) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Biometric quick login (also available in email mode)
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
            onSubmitted: _handleEmailSignIn,
          ),
          const SizedBox(height: 8),

          // Forgot password
          Align(
            alignment: Alignment.centerRight,
            child: AuthTextButton(
              text: 'Mot de passe oublie?',
              onPressed: _isLoading ? null : _navigateToForgotPassword,
            ),
          ),
          const SizedBox(height: 24),

          // Sign in button
          AuthButton(
            text: 'Connexion',
            loadingText: 'Connexion en cours...',
            isLoading: _isLoading,
            onPressed: _handleEmailSignIn,
          ),
          const SizedBox(height: 24),

          // Switch to phone mode
          Center(
            child: AuthTextButton(
              text: 'Connexion par telephone',
              onPressed: _isLoading
                  ? null
                  : () => setState(() => _mode = SignInMode.phone),
            ),
          ),
        ],
      ),
    );
  }
}
