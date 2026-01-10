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

  /// Deep link URL scheme for auth redirects
  static const String _redirectUrl = 'ca.trilogis.gpstracker://callback';

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
      throw const AuthServiceException('Sign in failed. Please try again.');
    }
  }

  /// Create a new account with email and password
  ///
  /// Returns [AuthResponse] on success. User must verify email before signing in.
  /// Throws [AuthServiceException] on failure.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
        emailRedirectTo: _redirectUrl,
      );
      return response;
    } on AuthException catch (e) {
      throw AuthServiceException(
        _mapAuthErrorToMessage(e.message),
        code: e.statusCode,
      );
    } catch (e) {
      throw const AuthServiceException('Sign up failed. Please try again.');
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
      throw const AuthServiceException('Failed to send reset email. Please try again.');
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
      throw const AuthServiceException('Failed to update password. Please try again.');
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
      return 'Invalid email or password';
    }
    if (lowerError.contains('email not confirmed') ||
        lowerError.contains('email_not_confirmed')) {
      return 'Please verify your email first';
    }
    if (lowerError.contains('already registered') ||
        lowerError.contains('email_exists') ||
        lowerError.contains('user already registered')) {
      return 'An account with this email already exists';
    }
    if (lowerError.contains('weak password') ||
        lowerError.contains('weak_password')) {
      return 'Password must be at least 8 characters';
    }
    if (lowerError.contains('rate limit') ||
        lowerError.contains('over_request_rate_limit') ||
        lowerError.contains('over_email_send_rate_limit')) {
      return 'Too many attempts. Please wait a few minutes.';
    }
    if (lowerError.contains('same password') ||
        lowerError.contains('same_password')) {
      return 'New password must be different from current password';
    }
    if (lowerError.contains('network') || lowerError.contains('connection')) {
      return 'Network error. Please check your connection.';
    }

    // Return original message if no mapping found
    return error;
  }
}
