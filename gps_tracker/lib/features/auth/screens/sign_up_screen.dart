import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../services/auth_service.dart';
import '../services/device_info_service.dart';
import '../services/validators.dart';
import '../widgets/auth_button.dart';
import '../widgets/auth_form_field.dart';

/// Sign up screen for creating new employee accounts
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _firstNameFocusNode = FocusNode();
  final _lastNameFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _registrationComplete = false;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameFocusNode.dispose();
    _lastNameFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSignUp() async {
    // Validate form
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authService = ref.read(authServiceProvider);
      final fullName =
          '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}';
      await authService.signUp(
        email: _emailController.text,
        password: _passwordController.text,
        fullName: fullName,
      );

      // Sync device info (fire-and-forget)
      final client = ref.read(supabaseClientProvider);
      DeviceInfoService(client).syncDeviceInfo();

      // Show success state
      if (mounted) {
        setState(() => _registrationComplete = true);
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
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show success screen after registration
    if (_registrationComplete) {
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
                  'Vérifiez votre courriel',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Nous avons envoyé un lien de vérification à :',
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
                    'Cliquez sur le lien dans votre courriel pour vérifier votre compte, puis revenez ici pour vous connecter.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 32),
                AuthButton(
                  text: 'Retour à la connexion',
                  onPressed: _navigateToSignIn,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show registration form
    return Scaffold(
      appBar: AppBar(
        title: const Text('Créer un compte'),
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
                  // Title
                  Text(
                    'Commençons',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Créez votre compte pour commencer le suivi',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // First name field
                  AuthFormField(
                    controller: _firstNameController,
                    focusNode: _firstNameFocusNode,
                    label: 'Prénom',
                    hint: 'Entrez votre prénom',
                    prefixIcon: Icons.person_outline,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.name,
                    enabled: !_isLoading,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Le prénom est requis';
                      }
                      if (value.trim().length < 2) {
                        return 'Le prénom doit contenir au moins 2 caractères';
                      }
                      return null;
                    },
                    onSubmitted: () => _lastNameFocusNode.requestFocus(),
                  ),
                  const SizedBox(height: 16),

                  // Last name field
                  AuthFormField(
                    controller: _lastNameController,
                    focusNode: _lastNameFocusNode,
                    label: 'Nom de famille',
                    hint: 'Entrez votre nom de famille',
                    prefixIcon: Icons.person_outline,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.name,
                    enabled: !_isLoading,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Le nom de famille est requis';
                      }
                      if (value.trim().length < 2) {
                        return 'Le nom de famille doit contenir au moins 2 caractères';
                      }
                      return null;
                    },
                    onSubmitted: () => _emailFocusNode.requestFocus(),
                  ),
                  const SizedBox(height: 16),

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
                    textInputAction: TextInputAction.next,
                    onToggleVisibility: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                    validator: PasswordValidator.validate,
                    enabled: !_isLoading,
                    onSubmitted: () => _confirmPasswordFocusNode.requestFocus(),
                  ),
                  const SizedBox(height: 8),

                  // Password requirements hint
                  Text(
                    'Le mot de passe doit contenir au moins 8 caractères avec lettres et chiffres',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Confirm password field
                  AuthFormField.password(
                    controller: _confirmPasswordController,
                    focusNode: _confirmPasswordFocusNode,
                    label: 'Confirmer le mot de passe',
                    hint: 'Entrez à nouveau votre mot de passe',
                    obscureText: _obscureConfirmPassword,
                    onToggleVisibility: () {
                      setState(
                        () => _obscureConfirmPassword = !_obscureConfirmPassword,
                      );
                    },
                    validator: (value) => PasswordValidator.validateConfirmation(
                      _passwordController.text,
                      value,
                    ),
                    enabled: !_isLoading,
                    onSubmitted: _handleSignUp,
                  ),
                  const SizedBox(height: 32),

                  // Sign up button
                  AuthButton(
                    text: 'Créer le compte',
                    loadingText: 'Création du compte...',
                    isLoading: _isLoading,
                    onPressed: _handleSignUp,
                  ),
                  const SizedBox(height: 24),

                  // Sign in link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Vous avez déjà un compte ? ',
                        style: theme.textTheme.bodyMedium,
                      ),
                      AuthTextButton(
                        text: 'Se connecter',
                        onPressed: _isLoading ? null : _navigateToSignIn,
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
