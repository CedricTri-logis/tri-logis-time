import 'package:supabase_flutter/supabase_flutter.dart';

/// Exception thrown for authentication errors
class AuthServiceException implements Exception {
  final String message;
  final String? code;

  const AuthServiceException(this.message, {this.code});

  @override
  String toString() => 'AuthServiceException: $message';
}

/// Service class wrapping Supabase authentication methods
///
/// Provides a clean interface for auth operations with proper
/// error handling and user-friendly error messages.
class AuthService {
  final SupabaseClient _client;

  /// Web redirect URL for auth (redirects to deep link)
  static const String _redirectUrl = 'https://time.trilogis.ca/auth/callback';

  AuthService(this._client);

  /// Get the current authenticated user
  User? get currentUser => _client.auth.currentUser;

  /// Get the current session
  Session? get currentSession => _client.auth.currentSession;

  /// Stream of auth state changes
  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  /// Sign in with email and password
  ///
  /// Returns [AuthResponse] on success.
  /// Throws [AuthServiceException] on failure with user-friendly message.
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException('Connexion échouée. Veuillez réessayer.');
    }
  }

  /// Create a new account with email and password
  ///
  /// Returns [AuthResponse] on success. User must verify email before signing in.
  /// Throws [AuthServiceException] on failure.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? fullName,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
        emailRedirectTo: _redirectUrl,
        data: fullName != null ? {'full_name': fullName} : null,
      );
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException('Inscription échouée. Veuillez réessayer.');
    }
  }

  /// Sign out the current user
  ///
  /// Clears local session. Does not throw on network failure
  /// as local session is cleared regardless.
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      // Sign out should still clear local session even if network fails
      // Supabase SDK handles this automatically
    }
  }

  /// Send password reset email
  ///
  /// Always succeeds (even for non-existent emails) to prevent email enumeration.
  /// Throws [AuthServiceException] only on rate limiting.
  Future<void> resetPassword(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(
        email.trim().toLowerCase(),
        redirectTo: _redirectUrl,
      );
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException('Impossible d\'envoyer le courriel de réinitialisation. Veuillez réessayer.');
    }
  }

  /// Update the current user's password
  ///
  /// Requires valid session (typically from password recovery link).
  /// Throws [AuthServiceException] on failure.
  Future<void> updatePassword(String newPassword) async {
    try {
      await _client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException('Impossible de mettre à jour le mot de passe. Veuillez réessayer.');
    }
  }

  /// Send an OTP code via SMS to the given phone number
  Future<void> sendOtp({required String phone}) async {
    try {
      await _client.auth.signInWithOtp(phone: phone);
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException(
        'Impossible d\'envoyer le code. Veuillez reessayer.',
      );
    }
  }

  /// Verify an SMS OTP code and sign in
  Future<AuthResponse> verifyOtp({
    required String phone,
    required String token,
  }) async {
    try {
      final response = await _client.auth.verifyOTP(
        phone: phone,
        token: token,
        type: OtpType.sms,
      );
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException(
        'Verification echouee. Veuillez reessayer.',
      );
    }
  }

  /// Restore a session from saved tokens (for biometric login)
  Future<AuthResponse> restoreSession({
    required String refreshToken,
  }) async {
    try {
      final response = await _client.auth.setSession(refreshToken);
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException(
        'Session expiree. Reconnectez-vous.',
      );
    }
  }

  /// Register a phone number on the current user's auth account
  /// (triggers phone verification OTP)
  Future<void> registerPhone({required String phone}) async {
    try {
      await _client.auth.updateUser(
        UserAttributes(phone: phone),
      );
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException(
        'Impossible d\'enregistrer le telephone. Veuillez reessayer.',
      );
    }
  }

  /// Verify a phone change OTP (after registerPhone)
  Future<AuthResponse> verifyPhoneChange({
    required String phone,
    required String token,
  }) async {
    try {
      final response = await _client.auth.verifyOTP(
        phone: phone,
        token: token,
        type: OtpType.phoneChange,
      );
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException(
        'Verification echouee. Veuillez reessayer.',
      );
    }
  }

  /// Save phone number to employee_profiles via RPC
  Future<void> savePhoneToProfile({required String phone}) async {
    try {
      await _client.rpc<void>('register_phone_number', params: {'p_phone': phone});
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('unique_violation') || msg.contains('deja associe')) {
        throw const AuthServiceException(
          'Ce numero est deja associe a un autre employe.',
        );
      }
      if (msg.contains('check_violation') || msg.contains('format invalide')) {
        throw const AuthServiceException(
          'Format de numero invalide. Utilisez le format +1XXXXXXXXXX.',
        );
      }
      throw const AuthServiceException(
        'Impossible de sauvegarder le numero. Veuillez reessayer.',
      );
    }
  }

  /// Check if the current user has a phone number registered
  Future<bool> isPhoneRegistered() async {
    try {
      final result = await _client.rpc<bool>('check_phone_registered');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Refresh the current session
  ///
  /// Called automatically by SDK, but can be triggered manually.
  Future<void> refreshSession() async {
    try {
      await _client.auth.refreshSession();
    } catch (e) {
      // Silent failure - session will be refreshed when network is available
    }
  }

  /// Map Supabase auth error messages to user-friendly messages
  String _mapAuthErrorToMessage(String error) {
    final lowerError = error.toLowerCase();

    if (lowerError.contains('invalid') && lowerError.contains('credentials') ||
        lowerError.contains('invalid login credentials')) {
      return 'Courriel ou mot de passe invalide';
    }
    if (lowerError.contains('email not confirmed') ||
        lowerError.contains('email_not_confirmed')) {
      return 'Veuillez d\'abord vérifier votre courriel';
    }
    if (lowerError.contains('already registered') ||
        lowerError.contains('email_exists') ||
        lowerError.contains('user already registered')) {
      return 'Un compte avec ce courriel existe déjà';
    }
    if (lowerError.contains('weak password') ||
        lowerError.contains('weak_password')) {
      return 'Le mot de passe doit contenir au moins 8 caractères';
    }
    if (lowerError.contains('rate limit') ||
        lowerError.contains('over_request_rate_limit') ||
        lowerError.contains('over_email_send_rate_limit')) {
      return 'Trop de tentatives. Veuillez patienter quelques minutes.';
    }
    if (lowerError.contains('same password') ||
        lowerError.contains('same_password')) {
      return 'Le nouveau mot de passe doit être différent de l\'ancien';
    }
    if (lowerError.contains('network') || lowerError.contains('connection')) {
      return 'Erreur réseau. Vérifiez votre connexion.';
    }
    // SMS provider / Twilio errors (must be checked BEFORE OTP errors)
    if (lowerError.contains('sms_send_failed') ||
        lowerError.contains('error sending') && lowerError.contains('otp to provider')) {
      return 'Impossible d\'envoyer le SMS. Veuillez reessayer.';
    }
    // SMS OTP errors
    if (lowerError.contains('otp_expired') ||
        lowerError.contains('token has expired')) {
      return 'Code expire. Demandez un nouveau code.';
    }
    if (lowerError.contains('otp_disabled')) {
      return 'La verification par SMS n\'est pas activee.';
    }
    if (lowerError.contains('invalid_otp') ||
        lowerError.contains('token is invalid') ||
        lowerError.contains('otp is invalid')) {
      return 'Code invalide. Veuillez verifier.';
    }
    if (lowerError.contains('over_sms_send_rate_limit') ||
        lowerError.contains('sms send rate')) {
      return 'Trop de SMS. Attendez 30 secondes.';
    }
    if (lowerError.contains('phone') && lowerError.contains('not found') ||
        lowerError.contains('user not found')) {
      return 'Aucun compte associe a ce numero.';
    }

    // Return original message if no mapping found
    return error;
  }
}
