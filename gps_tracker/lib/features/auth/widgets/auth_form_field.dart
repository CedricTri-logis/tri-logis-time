import 'package:flutter/material.dart';

/// Reusable form field for authentication screens
///
/// Provides consistent styling and behavior for email and password inputs.
class AuthFormField extends StatelessWidget {
  /// Controller for the text field
  final TextEditingController controller;

  /// Label text shown above the field
  final String label;

  /// Hint text shown inside the field
  final String? hint;

  /// Whether this is a password field (obscured text)
  final bool obscureText;

  /// Keyboard type for the field
  final TextInputType keyboardType;

  /// Text input action (e.g., next, done)
  final TextInputAction textInputAction;

  /// Validation function returning error message or null if valid
  final String? Function(String?)? validator;

  /// Callback when field is submitted (e.g., pressing enter)
  final VoidCallback? onSubmitted;

  /// Whether the field is enabled
  final bool enabled;

  /// Whether to autocorrect (usually false for auth fields)
  final bool autocorrect;

  /// Suffix icon widget (e.g., password visibility toggle)
  final Widget? suffixIcon;

  /// Prefix icon widget
  final IconData? prefixIcon;

  /// Focus node for controlling focus
  final FocusNode? focusNode;

  const AuthFormField({
    required this.controller,
    required this.label,
    super.key,
    this.hint,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.next,
    this.validator,
    this.onSubmitted,
    this.enabled = true,
    this.autocorrect = false,
    this.suffixIcon,
    this.prefixIcon,
    this.focusNode,
  });

  /// Create an email form field with sensible defaults
  factory AuthFormField.email({
    required TextEditingController controller,
    Key? key,
    String? Function(String?)? validator,
    VoidCallback? onSubmitted,
    bool enabled = true,
    FocusNode? focusNode,
  }) {
    return AuthFormField(
      key: key,
      controller: controller,
      label: 'Email',
      hint: 'Enter your email',
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      validator: validator,
      onSubmitted: onSubmitted,
      enabled: enabled,
      prefixIcon: Icons.email_outlined,
      focusNode: focusNode,
    );
  }

  /// Create a password form field with sensible defaults
  factory AuthFormField.password({
    required TextEditingController controller,
    required bool obscureText,
    required VoidCallback onToggleVisibility,
    Key? key,
    String label = 'Password',
    String hint = 'Enter your password',
    String? Function(String?)? validator,
    VoidCallback? onSubmitted,
    bool enabled = true,
    TextInputAction textInputAction = TextInputAction.done,
    FocusNode? focusNode,
  }) {
    return AuthFormField(
      key: key,
      controller: controller,
      label: label,
      hint: hint,
      obscureText: obscureText,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: textInputAction,
      validator: validator,
      onSubmitted: onSubmitted,
      enabled: enabled,
      prefixIcon: Icons.lock_outlined,
      focusNode: focusNode,
      suffixIcon: IconButton(
        icon: Icon(
          obscureText ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
        onPressed: onToggleVisibility,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autocorrect: autocorrect,
      enableSuggestions: !obscureText,
      enabled: enabled,
      validator: validator,
      onFieldSubmitted: (_) => onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
        suffixIcon: suffixIcon,
        border: const OutlineInputBorder(),
        filled: true,
      ),
    );
  }
}
