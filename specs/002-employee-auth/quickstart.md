# Quickstart: Employee Authentication

**Feature Branch**: `002-employee-auth`
**Date**: 2026-01-08

## Prerequisites

Before implementing this feature, ensure:

1. **Spec 001 (Project Foundation) is complete**
   - Flutter project exists at `gps_tracker/`
   - Supabase initialized with `supabase_flutter`
   - `employee_profiles` table exists with RLS enabled

2. **Development environment ready**
   ```bash
   cd gps_tracker
   flutter pub get
   flutter analyze  # Should pass
   ```

3. **Supabase local dev running** (optional for testing)
   ```bash
   cd supabase
   supabase start
   ```

---

## Implementation Order

### Phase 1: Core Auth Service

1. **Create EmployeeProfile model**
   - `lib/features/auth/models/employee_profile.dart`
   - Immutable data class with fromJson/toJson

2. **Create AuthService**
   - `lib/features/auth/services/auth_service.dart`
   - Wrapper around supabase.auth methods
   - Error handling and mapping

3. **Update providers**
   - Extend `lib/shared/providers/supabase_provider.dart`
   - Add authServiceProvider

### Phase 2: Sign In Flow

4. **Create SignInScreen**
   - `lib/features/auth/screens/sign_in_screen.dart`
   - Email/password form with validation
   - Error display and loading state

5. **Create auth widgets**
   - `lib/features/auth/widgets/auth_form_field.dart`
   - `lib/features/auth/widgets/auth_button.dart`

6. **Wire up app routing**
   - Update `lib/app.dart` to show SignInScreen when unauthenticated

### Phase 3: Sign Up Flow

7. **Create SignUpScreen**
   - `lib/features/auth/screens/sign_up_screen.dart`
   - Email/password with password confirmation
   - Email verification instructions

8. **Add password validation**
   - Min 8 chars, letters + numbers (FR-006)

### Phase 4: Password Recovery

9. **Create ForgotPasswordScreen**
   - `lib/features/auth/screens/forgot_password_screen.dart`
   - Email input for reset request
   - Listen for passwordRecovery event

### Phase 5: Profile & Sign Out

10. **Create ProfileScreen**
    - `lib/features/auth/screens/profile_screen.dart`
    - Display and edit full_name
    - View email (read-only)

11. **Add ProfileProvider**
    - `lib/features/auth/providers/profile_provider.dart`
    - Fetch and update profile

12. **Add sign out to HomeScreen**
    - Update `lib/features/home/home_screen.dart`
    - Add settings/sign out option

### Phase 6: Auth Guard

13. **Create AuthGuard**
    - `lib/shared/routing/auth_guard.dart`
    - Protect routes from unauthenticated access

### Phase 7: Testing

14. **Unit tests**
    - AuthService tests
    - Profile provider tests

15. **Widget tests**
    - SignInScreen form validation
    - SignUpScreen form validation

16. **Integration test**
    - Full auth flow (sign up -> verify -> sign in -> sign out)

---

## Key Files to Create

```
gps_tracker/lib/
├── features/auth/
│   ├── models/
│   │   └── employee_profile.dart     # Data model
│   ├── providers/
│   │   ├── auth_provider.dart        # Auth state management
│   │   └── profile_provider.dart     # Profile CRUD
│   ├── screens/
│   │   ├── sign_in_screen.dart       # Login UI
│   │   ├── sign_up_screen.dart       # Registration UI
│   │   ├── forgot_password_screen.dart
│   │   └── profile_screen.dart       # Profile view/edit
│   ├── services/
│   │   └── auth_service.dart         # Supabase auth wrapper
│   └── widgets/
│       ├── auth_form_field.dart      # Styled text field
│       └── auth_button.dart          # Primary action button
└── shared/
    └── routing/
        └── auth_guard.dart           # Route protection
```

---

## Validation Requirements

### Email Validation
```dart
bool isValidEmail(String email) {
  return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
}
```

### Password Validation (FR-006)
```dart
String? validatePassword(String password) {
  if (password.length < 8) return 'At least 8 characters required';
  if (!RegExp(r'[a-zA-Z]').hasMatch(password)) return 'Must contain a letter';
  if (!RegExp(r'[0-9]').hasMatch(password)) return 'Must contain a number';
  return null;
}
```

---

## Testing Checklist

### Manual Testing

- [ ] New user can sign up with valid email/password
- [ ] Email verification email is received
- [ ] Verified user can sign in
- [ ] Invalid credentials show error message
- [ ] Unverified user sees appropriate message
- [ ] User stays signed in after app restart
- [ ] Password reset email is sent
- [ ] Password can be updated via reset link
- [ ] User can sign out
- [ ] Signed out user cannot access protected screens
- [ ] User can view profile information
- [ ] User can update display name
- [ ] Offline: app shows cached user info
- [ ] Rate limiting: rapid attempts show error

### Automated Testing

```bash
# Run unit tests
cd gps_tracker
flutter test test/features/auth/

# Run widget tests
flutter test test/widget/auth/

# Run integration tests (requires device/emulator)
flutter test integration_test/auth_flow_test.dart
```

---

## Environment Configuration

### Required .env Variables

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

### Supabase Dashboard Settings

1. **Enable Email Auth**
   - Authentication > Providers > Email > Enable

2. **Enable Email Confirmation** (recommended)
   - Authentication > Settings > Confirm email

3. **Configure Email Templates** (optional)
   - Authentication > Email Templates
   - Customize confirmation and reset emails

4. **Set JWT Expiry** (optional)
   - Project Settings > Authentication
   - Default: 3600 seconds (1 hour)
   - Recommended for mobile: 604800 (7 days)

---

## Common Issues

### "Email rate limit exceeded"
- Default is 2 emails/hour for development
- Solution: Configure custom SMTP in Supabase Dashboard

### "Email not confirmed"
- User hasn't clicked verification link
- Check spam folder
- Resend verification (not implemented in v1)

### Session lost after app restart
- Ensure `Supabase.initialize()` is called in `main.dart`
- Check that flutter_secure_storage is working

### RLS policy errors
- Ensure user is authenticated before profile queries
- Check that employee_profile was created via trigger

---

## Next Steps After Implementation

1. Run `/speckit.tasks` to generate implementation tasks
2. Create feature branch from `002-employee-auth`
3. Implement in order specified above
4. Run tests after each phase
5. Submit PR when complete
