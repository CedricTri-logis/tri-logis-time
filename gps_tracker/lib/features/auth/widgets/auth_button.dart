import 'package:flutter/material.dart';

/// Primary action button for authentication screens
///
/// Provides consistent styling and loading state handling.
class AuthButton extends StatelessWidget {
  /// Button text
  final String text;

  /// Callback when button is pressed
  final VoidCallback? onPressed;

  /// Whether the button is in loading state
  final bool isLoading;

  /// Loading text to show (defaults to regular text)
  final String? loadingText;

  const AuthButton({
    required this.text,
    super.key,
    this.onPressed,
    this.isLoading = false,
    this.loadingText,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(loadingText ?? text),
                ],
              )
            : Text(text),
      ),
    );
  }
}

/// Secondary/outline button for authentication screens
class AuthOutlineButton extends StatelessWidget {
  /// Button text
  final String text;

  /// Callback when button is pressed
  final VoidCallback? onPressed;

  /// Whether the button is disabled
  final bool disabled;

  const AuthOutlineButton({
    required this.text,
    super.key,
    this.onPressed,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton(
        onPressed: disabled ? null : onPressed,
        child: Text(text),
      ),
    );
  }
}

/// Text button for navigation links (e.g., "Forgot Password?")
class AuthTextButton extends StatelessWidget {
  /// Button text
  final String text;

  /// Callback when button is pressed
  final VoidCallback? onPressed;

  const AuthTextButton({
    required this.text,
    super.key,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      child: Text(text),
    );
  }
}
