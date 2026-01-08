# Research: Employee Authentication

**Feature Branch**: `002-employee-auth`
**Date**: 2026-01-08

## Research Tasks

| Topic | Status | Decision |
|-------|--------|----------|
| Supabase Auth with Flutter | Resolved | Use supabase_flutter built-in email/password auth |
| Riverpod Auth Patterns | Resolved | StreamProvider for auth state, service class pattern |
| Rate Limiting | Resolved | Client-side throttling + Supabase defaults |
| Offline Session Handling | Resolved | Allow local access, refresh on reconnect |
| Route Protection | Resolved | Simple Navigator-based auth guard (no go_router) |

---

## 1. Supabase Auth with Flutter

### Decision

Use `supabase_flutter` built-in authentication with email/password. No additional packages needed.

### Rationale

- `supabase_flutter` v2.12.0 already includes all auth functionality
- Session persistence is automatic via `flutter_secure_storage`
- Token refresh is handled automatically in the background
- Well-documented with clear error codes

### Key Implementation Patterns

**Sign-Up with Email Verification:**
```dart
final response = await supabase.auth.signUp(
  email: email,
  password: password,
);
// User needs to verify email before signing in
```

**Sign-In:**
```dart
final response = await supabase.auth.signInWithPassword(
  email: email,
  password: password,
);
```

**Password Reset:**
```dart
await supabase.auth.resetPasswordForEmail(email);
// User receives email with magic link
// Listen for AuthChangeEvent.passwordRecovery
```

**Error Handling:**
| Error Code | User-Friendly Message |
|------------|----------------------|
| `invalid_credentials` | Invalid email or password |
| `email_not_confirmed` | Please verify your email first |
| `email_exists` | An account with this email already exists |
| `weak_password` | Password must be at least 8 characters |
| `over_request_rate_limit` | Too many attempts. Please wait. |

### Alternatives Considered

1. **Firebase Auth** - Rejected: Constitution specifies Supabase
2. **Custom JWT auth** - Rejected: Over-engineering, Supabase Auth is sufficient

---

## 2. Riverpod Auth State Management

### Decision

Use StreamProvider for auth state with a service class pattern. Avoid code generation (`riverpod_annotation`) for simplicity.

### Rationale

- StreamProvider naturally fits Supabase's `onAuthStateChange` stream
- Service class pattern keeps auth logic testable and isolated
- No build_runner dependency simplifies development
- Consistent with Constitution V (Simplicity & Maintainability)

### Implementation Pattern

**Auth State Provider:**
```dart
// In shared/providers/supabase_provider.dart (already exists)
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseClientProvider).auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(supabaseClientProvider).auth.currentUser;
});

final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider) != null;
});
```

**Auth Service (new):**
```dart
class AuthService {
  final SupabaseClient _client;

  AuthService(this._client);

  Future<AuthResponse> signIn({required String email, required String password});
  Future<AuthResponse> signUp({required String email, required String password});
  Future<void> signOut();
  Future<void> resetPassword(String email);
  Future<void> updatePassword(String newPassword);
}
```

### Alternatives Considered

1. **AsyncNotifier with code generation** - Rejected: Adds build_runner complexity
2. **StateNotifier** - Rejected: Legacy pattern, StreamProvider is more idiomatic

---

## 3. Rate Limiting

### Decision

Implement client-side throttling for sign-in attempts (5 attempts per 15 minutes). Rely on Supabase's server-side rate limits as backup.

### Rationale

- FR-013 requires rate limiting on authentication attempts
- Supabase has built-in rate limits but better UX to prevent before hitting server
- Client-side provides immediate feedback to user

### Supabase Default Limits

| Operation | Limit |
|-----------|-------|
| Email sends (signup, reset) | 2/hour (increase with custom SMTP) |
| Token refresh | 1,800/hour |
| Verification requests | 360/hour |

### Implementation

```dart
class AuthRateLimiter {
  static const maxAttempts = 5;
  static const windowMinutes = 15;

  final List<DateTime> _attempts = [];

  bool canAttempt() {
    _cleanOldAttempts();
    return _attempts.length < maxAttempts;
  }

  void recordAttempt() {
    _attempts.add(DateTime.now());
  }

  Duration? getRemainingLockout() {
    if (canAttempt()) return null;
    final oldest = _attempts.first;
    final unlockTime = oldest.add(Duration(minutes: windowMinutes));
    return unlockTime.difference(DateTime.now());
  }
}
```

### Alternatives Considered

1. **Server-side only** - Rejected: Poor UX, cryptic error messages
2. **CAPTCHA integration** - Rejected: Over-engineering for employee app

---

## 4. Offline Session Handling

### Decision

Allow local app access with cached session. Attempt token refresh when connectivity returns. Never force logout due to network issues.

### Rationale

- Constitution IV requires offline-first architecture
- Employees may work in areas with poor connectivity
- Auth operations require network, but session persistence doesn't
- Better UX to maintain access and sync when possible

### Implementation Pattern

```dart
class ConnectivityAwareAuthGuard {
  Future<bool> canAccessProtectedRoute() async {
    final session = supabase.auth.currentSession;

    // No session at all = must sign in
    if (session == null) return false;

    // Has session (even if expired) = allow local access
    // Token refresh happens automatically when online
    return true;
  }

  Future<void> refreshSessionIfOnline() async {
    if (!await hasConnectivity()) return;

    final session = supabase.auth.currentSession;
    if (session?.isExpired == true) {
      try {
        await supabase.auth.refreshSession();
      } catch (e) {
        // Silent fail - don't disrupt user
      }
    }
  }
}
```

### Alternatives Considered

1. **Force logout on expired token** - Rejected: Violates Constitution IV
2. **Manual session storage** - Rejected: supabase_flutter handles this automatically

---

## 5. Route Protection Strategy

### Decision

Use simple Navigator-based auth guard. No go_router dependency.

### Rationale

- Current app uses Navigator with MaterialApp
- Adding go_router would be over-engineering (Constitution V)
- Simple StreamBuilder-based routing is sufficient for 5 auth screens

### Implementation Pattern

```dart
// In app.dart
class GpsTrackerApp extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateChangesProvider);

    return MaterialApp(
      home: authState.when(
        data: (state) => state.session != null
            ? const HomeScreen()
            : const SignInScreen(),
        loading: () => const SplashScreen(),
        error: (_, __) => const SignInScreen(),
      ),
    );
  }
}
```

### Alternatives Considered

1. **go_router** - Rejected: Adds dependency, current Navigator sufficient
2. **Auto_route** - Rejected: Unnecessary for simple auth flow

---

## Password Validation Requirements

Per FR-006: Minimum 8 characters, containing letters and numbers.

```dart
class PasswordValidator {
  static String? validate(String? password) {
    if (password == null || password.isEmpty) {
      return 'Password is required';
    }
    if (password.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (!RegExp(r'[a-zA-Z]').hasMatch(password)) {
      return 'Password must contain at least one letter';
    }
    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Password must contain at least one number';
    }
    return null;
  }
}
```

---

## Email Validation

```dart
class EmailValidator {
  static String? validate(String? email) {
    if (email == null || email.isEmpty) {
      return 'Email is required';
    }
    // Basic email regex - Supabase will do final validation
    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      return 'Enter a valid email address';
    }
    return null;
  }
}
```

---

## Sources

- Supabase Auth Docs: https://supabase.com/docs/guides/auth/passwords
- supabase_flutter package: https://pub.dev/packages/supabase_flutter
- Supabase Rate Limits: https://supabase.com/docs/guides/auth/rate-limits
- Supabase Error Codes: https://supabase.com/docs/guides/auth/debugging/error-codes
