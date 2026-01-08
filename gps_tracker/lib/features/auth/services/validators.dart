/// Email validation utility
class EmailValidator {
  EmailValidator._();

  /// Validates an email address
  ///
  /// Returns null if valid, or an error message if invalid.
  static String? validate(String? email) {
    if (email == null || email.isEmpty) {
      return 'Email is required';
    }

    final trimmed = email.trim();

    // Basic email regex - Supabase will do final validation
    if (!RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,}$').hasMatch(trimmed)) {
      return 'Enter a valid email address';
    }

    return null;
  }

  /// Check if email is valid without error message
  static bool isValid(String? email) => validate(email) == null;
}

/// Password validation utility
///
/// Requirements per FR-006:
/// - Minimum 8 characters
/// - Must contain at least one letter
/// - Must contain at least one number
class PasswordValidator {
  PasswordValidator._();

  /// Minimum password length
  static const int minLength = 8;

  /// Validates a password
  ///
  /// Returns null if valid, or an error message if invalid.
  static String? validate(String? password) {
    if (password == null || password.isEmpty) {
      return 'Password is required';
    }

    if (password.length < minLength) {
      return 'Password must be at least $minLength characters';
    }

    if (!RegExp(r'[a-zA-Z]').hasMatch(password)) {
      return 'Password must contain at least one letter';
    }

    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Password must contain at least one number';
    }

    return null;
  }

  /// Check if password is valid without error message
  static bool isValid(String? password) => validate(password) == null;

  /// Validates password confirmation matches password
  ///
  /// Returns null if matches, or an error message if not.
  static String? validateConfirmation(String? password, String? confirmation) {
    if (confirmation == null || confirmation.isEmpty) {
      return 'Please confirm your password';
    }

    if (password != confirmation) {
      return 'Passwords do not match';
    }

    return null;
  }
}
