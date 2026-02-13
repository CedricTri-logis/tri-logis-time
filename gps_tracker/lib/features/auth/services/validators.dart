/// Email validation utility
class EmailValidator {
  EmailValidator._();

  /// Validates an email address
  ///
  /// Returns null if valid, or an error message if invalid.
  static String? validate(String? email) {
    if (email == null || email.isEmpty) {
      return 'Le courriel est requis';
    }

    final trimmed = email.trim();

    // Basic email regex - Supabase will do final validation
    if (!RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,}$').hasMatch(trimmed)) {
      return 'Entrez une adresse courriel valide';
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
      return 'Le mot de passe est requis';
    }

    if (password.length < minLength) {
      return 'Le mot de passe doit avoir au moins $minLength caractères';
    }

    if (!RegExp(r'[a-zA-Z]').hasMatch(password)) {
      return 'Le mot de passe doit contenir au moins une lettre';
    }

    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Le mot de passe doit contenir au moins un chiffre';
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
      return 'Veuillez confirmer votre mot de passe';
    }

    if (password != confirmation) {
      return 'Les mots de passe ne correspondent pas';
    }

    return null;
  }
}
