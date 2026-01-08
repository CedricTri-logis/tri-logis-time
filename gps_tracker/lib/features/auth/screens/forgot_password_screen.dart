import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../services/auth_service.dart';
import '../services/validators.dart';
import '../widgets/auth_button.dart';
import '../widgets/auth_form_field.dart';

/// Forgot password screen for password recovery
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _emailSent = false;
  bool _showPasswordReset = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _passwordResetComplete = false;

  @override
  void initState() {
    super.initState();
    _setupAuthListener();
  }

  void _setupAuthListener() {
    // Listen for password recovery event from auth state
    ref.read(supabaseClientProvider).auth.onAuthStateChange.listen((data) {
      final event = data.event;
      if (event == AuthChangeEvent.passwordRecovery && mounted) {
        setState(() => _showPasswordReset = true);
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSendResetLink() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);
      await authService.resetPassword(_emailController.text);

      if (mounted) {
        setState(() => _emailSent = true);
      }
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

  Future<void> _handleUpdatePassword() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);
      await authService.updatePassword(_newPasswordController.text);

      if (mounted) {
        setState(() => _passwordResetComplete = true);
      }
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

  void _navigateToSignIn() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show password reset complete screen
    if (_passwordResetComplete) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 80,
                  color: Colors.green,
                ),
                const SizedBox(height: 24),
                Text(
                  'Password Updated',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Your password has been successfully updated. You can now sign in with your new password.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                AuthButton(
                  text: 'Back to Sign In',
                  onPressed: _navigateToSignIn,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show new password form (after clicking reset link)
    if (_showPasswordReset) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Set New Password'),
        ),
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
                    Text(
                      'Create New Password',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter your new password below',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // New password field
                    AuthFormField.password(
                      controller: _newPasswordController,
                      label: 'New Password',
                      hint: 'Enter new password',
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.next,
                      onToggleVisibility: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                      validator: PasswordValidator.validate,
                      enabled: !_isLoading,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Password must be at least 8 characters with letters and numbers',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Confirm password field
                    AuthFormField.password(
                      controller: _confirmPasswordController,
                      label: 'Confirm New Password',
                      hint: 'Re-enter new password',
                      obscureText: _obscureConfirmPassword,
                      onToggleVisibility: () {
                        setState(
                          () => _obscureConfirmPassword = !_obscureConfirmPassword,
                        );
                      },
                      validator: (value) =>
                          PasswordValidator.validateConfirmation(
                        _newPasswordController.text,
                        value,
                      ),
                      enabled: !_isLoading,
                      onSubmitted: _handleUpdatePassword,
                    ),
                    const SizedBox(height: 32),

                    AuthButton(
                      text: 'Update Password',
                      loadingText: 'Updating...',
                      isLoading: _isLoading,
                      onPressed: _handleUpdatePassword,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Show email sent success screen
    if (_emailSent) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.mark_email_read_outlined,
                  size: 80,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Check Your Email',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'We sent a password reset link to:',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _emailController.text,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Click the link in your email to reset your password. The link will expire in 1 hour.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 32),
                AuthButton(
                  text: 'Back to Sign In',
                  onPressed: _navigateToSignIn,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show initial email input form
    return Scaffold(
      appBar: AppBar(
        title: const Text('Forgot Password'),
      ),
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
                  Icon(
                    Icons.lock_reset_outlined,
                    size: 80,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Reset Password',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your email address and we\'ll send you a link to reset your password.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Email field
                  AuthFormField.email(
                    controller: _emailController,
                    validator: EmailValidator.validate,
                    enabled: !_isLoading,
                    onSubmitted: _handleSendResetLink,
                  ),
                  const SizedBox(height: 32),

                  // Send reset link button
                  AuthButton(
                    text: 'Send Reset Link',
                    loadingText: 'Sending...',
                    isLoading: _isLoading,
                    onPressed: _handleSendResetLink,
                  ),
                  const SizedBox(height: 24),

                  // Back to sign in link
                  Center(
                    child: AuthTextButton(
                      text: 'Back to Sign In',
                      onPressed: _isLoading ? null : _navigateToSignIn,
                    ),
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
