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

/// Phone number validation utility for Canadian numbers
class PhoneValidator {
  PhoneValidator._();

  /// Strips all non-digit characters from the input
  static String _stripNonDigits(String input) {
    return input.replaceAll(RegExp(r'[^\d]'), '');
  }

  /// Normalizes various Canadian phone formats to E.164 (+1XXXXXXXXXX).
  ///
  /// Accepts: `5145551234`, `(514) 555-1234`, `1-514-555-1234`,
  /// `+1 514 555 1234`, `514.555.1234`, etc.
  /// Returns null if the input cannot be normalized.
  static String? normalizeToE164(String input) {
    final digits = _stripNonDigits(input);

    // 10 digits: local Canadian number (e.g. 5145551234)
    if (digits.length == 10) {
      return '+1$digits';
    }

    // 11 digits starting with 1: full Canadian number (e.g. 15145551234)
    if (digits.length == 11 && digits.startsWith('1')) {
      return '+$digits';
    }

    return null;
  }

  /// Validates a phone number.
  ///
  /// Returns null if valid, or an error message in French if invalid.
  static String? validate(String? phone) {
    if (phone == null || phone.isEmpty) {
      return 'Le numero de telephone est requis';
    }

    final normalized = normalizeToE164(phone);
    if (normalized == null) {
      return 'Entrez un numero de telephone canadien valide (10 chiffres)';
    }

    // Validate area code starts with 2-9
    final areaCode = normalized.substring(2, 3);
    if (int.parse(areaCode) < 2) {
      return 'Entrez un numero de telephone canadien valide (10 chiffres)';
    }

    return null;
  }

  /// Check if phone is valid without error message
  static bool isValid(String? phone) => validate(phone) == null;

  /// Formats a 10-digit number for display: (514) 555-1234
  static String formatForDisplay(String e164) {
    final digits = _stripNonDigits(e164);
    final local = digits.length == 11 ? digits.substring(1) : digits;
    if (local.length != 10) return e164;
    return '(${local.substring(0, 3)}) ${local.substring(3, 6)}-${local.substring(6)}';
  }
}
