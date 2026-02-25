import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/theme.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/validators.dart';
import '../widgets/otp_input_field.dart';
import '../widgets/otp_resend_button.dart';
import '../widgets/phone_form_field.dart';

/// States for the phone registration flow
enum _RegistrationStep { enterPhone, verifyOtp, setupBiometric, complete }

/// Phone registration screen shown after login when user has no phone number.
/// When [canSkip] is true, a "Plus tard" button lets the user defer for 7 days.
class PhoneRegistrationScreen extends ConsumerStatefulWidget {
  final bool canSkip;

  /// Called when registration is completed or skipped (replaces Navigator.pop).
  final VoidCallback? onCompleted;

  const PhoneRegistrationScreen({
    super.key,
    this.canSkip = false,
    this.onCompleted,
  });

  @override
  ConsumerState<PhoneRegistrationScreen> createState() =>
      _PhoneRegistrationScreenState();
}

class _PhoneRegistrationScreenState
    extends ConsumerState<PhoneRegistrationScreen> {
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  final _otpKey = GlobalKey<OtpInputFieldState>();

  _RegistrationStep _step = _RegistrationStep.enterPhone;
  bool _isLoading = false;
  String _normalizedPhone = '';
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _checkBiometric() async {
    final bio = ref.read(biometricServiceProvider);
    final available = await bio.isAvailable();
    if (mounted) {
      setState(() => _biometricAvailable = available);
    }
  }

  /// Extract raw digits from the formatted phone field
  String get _rawDigits =>
      _phoneController.text.replaceAll(RegExp(r'[^\d]'), '');

  Future<void> _handleSendCode() async {
    // Validate phone
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
      // Register the phone on the auth account (sends OTP)
      await authService.registerPhone(phone: normalized);

      _normalizedPhone = normalized;
      if (mounted) {
        setState(() {
          _step = _RegistrationStep.verifyOtp;
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
    // Guard against double-submission (OTP widget can fire onCompleted twice)
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);

      // Verify the phone change OTP
      await authService.verifyPhoneChange(
        phone: _normalizedPhone,
        token: code,
      );

      // Signal autofill framework that verification is complete
      TextInput.finishAutofillContext();

      // Save to employee_profiles via RPC
      await authService.savePhoneToProfile(phone: _normalizedPhone);

      // Save biometric tokens now that phone is verified (with phone for OTP fallback)
      final session = ref.read(supabaseClientProvider).auth.currentSession;
      if (session != null) {
        final bio = ref.read(biometricServiceProvider);
        await bio.saveSessionTokens(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken!,
          phone: _normalizedPhone,
        );
      }

      if (mounted) {
        if (_biometricAvailable) {
          setState(() {
            _step = _RegistrationStep.setupBiometric;
            _isLoading = false;
          });
        } else {
          setState(() {
            _step = _RegistrationStep.complete;
            _isLoading = false;
          });
        }
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _otpKey.currentState?.clear();
        ErrorSnackbar.show(context, e.message);
      }
    }
  }

  Future<void> _handleResendOtp() async {
    try {
      final authService = ref.read(authServiceProvider);
      await authService.registerPhone(phone: _normalizedPhone);
      if (mounted) {
        ErrorSnackbar.showSuccess(context, 'Nouveau code envoye');
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        ErrorSnackbar.show(context, e.message);
      }
    }
  }

  Future<void> _handleEnableBiometric() async {
    final session = ref.read(supabaseClientProvider).auth.currentSession;
    if (session != null) {
      final bio = ref.read(biometricServiceProvider);
      await bio.saveSessionTokens(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken!,
        phone: _normalizedPhone.isNotEmpty ? _normalizedPhone : null,
      );
    }
    if (mounted) {
      setState(() => _step = _RegistrationStep.complete);
    }
  }

  void _handleSkipBiometric() {
    setState(() => _step = _RegistrationStep.complete);
  }

  Future<void> _handleSkipRegistration() async {
    // Store skip timestamp for 7-day grace period
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'phone_registration_skipped_at',
      value: DateTime.now().toIso8601String(),
    );
    if (mounted) {
      _notifyCompleted();
    }
  }

  /// Notify parent that registration flow is done (completed or skipped).
  void _notifyCompleted() {
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  void _handleChangeNumber() {
    setState(() {
      _step = _RegistrationStep.enterPhone;
    });
  }

  String get _biometricLabel {
    if (Platform.isIOS) return 'Face ID';
    return 'Empreinte digitale';
  }

  IconData get _biometricIcon {
    if (Platform.isIOS) return Icons.face;
    return Icons.fingerprint;
  }

  @override
  Widget build(BuildContext context) {
    // Auto-navigate when complete
    if (_step == _RegistrationStep.complete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _notifyCompleted();
        }
      });
    }

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
                      height: 80,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // Step-specific content
                if (_step == _RegistrationStep.enterPhone)
                  _buildEnterPhoneStep(theme),
                if (_step == _RegistrationStep.verifyOtp)
                  _buildVerifyOtpStep(theme),
                if (_step == _RegistrationStep.setupBiometric)
                  _buildSetupBiometricStep(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEnterPhoneStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enregistrer votre telephone',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: TriLogisColors.black,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Ajoutez votre numero pour vous connecter par SMS lors de vos prochaines visites.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        PhoneFormField(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          enabled: !_isLoading,
          onSubmitted: _handleSendCode,
        ),
        const SizedBox(height: 24),

        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: _isLoading ? null : _handleSendCode,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Text('Envoyer le code'),
          ),
        ),

        if (widget.canSkip) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: _isLoading ? null : _handleSkipRegistration,
              child: const Text('Plus tard'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVerifyOtpStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Verification',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: TriLogisColors.black,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Code envoye au ${PhoneValidator.formatForDisplay(_normalizedPhone)}',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Le SMS peut prendre jusqu\'a 2 minutes.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.grey[500],
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
              onPressed: _handleChangeNumber,
              child: const Text('Changer de numero'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSetupBiometricStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          _biometricIcon,
          size: 64,
          color: TriLogisColors.gold,
        ),
        const SizedBox(height: 24),
        Text(
          'Activer $_biometricLabel?',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: TriLogisColors.black,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Connectez-vous plus rapidement en utilisant $_biometricLabel lors de vos prochaines visites.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: _handleEnableBiometric,
            icon: Icon(_biometricIcon),
            label: Text('Activer $_biometricLabel'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: OutlinedButton(
            onPressed: _handleSkipBiometric,
            child: const Text('Plus tard'),
          ),
        ),
      ],
    );
  }
}
