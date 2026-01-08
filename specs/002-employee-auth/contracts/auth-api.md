# Auth API Contracts

**Feature Branch**: `002-employee-auth`
**Date**: 2026-01-08

## Overview

Authentication uses Supabase Auth REST API through the `supabase_flutter` SDK. This document specifies the expected request/response contracts for reference and testing.

All endpoints use the Supabase base URL configured in `.env` as `SUPABASE_URL`.

---

## Authentication Endpoints

### 1. Sign Up (Create Account)

**SDK Method**: `supabase.auth.signUp()`

**Request**:
```json
{
  "email": "employee@company.com",
  "password": "SecurePass123"
}
```

**Success Response** (201):
```json
{
  "user": {
    "id": "uuid-here",
    "email": "employee@company.com",
    "email_confirmed_at": null,
    "created_at": "2026-01-08T10:00:00Z",
    "updated_at": "2026-01-08T10:00:00Z"
  },
  "session": null
}
```

Note: Session is null until email is verified.

**Error Responses**:

| Status | Error Code | Message |
|--------|------------|---------|
| 422 | `email_exists` | User already registered |
| 422 | `weak_password` | Password should be at least 6 characters |
| 429 | `over_email_send_rate_limit` | Email rate limit exceeded |

---

### 2. Sign In (Email/Password)

**SDK Method**: `supabase.auth.signInWithPassword()`

**Request**:
```json
{
  "email": "employee@company.com",
  "password": "SecurePass123"
}
```

**Success Response** (200):
```json
{
  "user": {
    "id": "uuid-here",
    "email": "employee@company.com",
    "email_confirmed_at": "2026-01-08T10:05:00Z",
    "created_at": "2026-01-08T10:00:00Z",
    "updated_at": "2026-01-08T10:05:00Z"
  },
  "session": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "abc123...",
    "expires_in": 3600,
    "expires_at": 1704715600,
    "token_type": "bearer"
  }
}
```

**Error Responses**:

| Status | Error Code | Message |
|--------|------------|---------|
| 400 | `invalid_credentials` | Invalid login credentials |
| 400 | `email_not_confirmed` | Email not confirmed |
| 429 | `over_request_rate_limit` | Request rate limit exceeded |

---

### 3. Sign Out

**SDK Method**: `supabase.auth.signOut()`

**Request**: No body required (uses current session token)

**Success Response** (200):
```json
{}
```

**Note**: Local session is cleared regardless of response.

---

### 4. Password Reset Request

**SDK Method**: `supabase.auth.resetPasswordForEmail()`

**Request**:
```json
{
  "email": "employee@company.com"
}
```

**Success Response** (200):
```json
{}
```

Note: Always returns success (even for non-existent emails) to prevent email enumeration.

**Error Responses**:

| Status | Error Code | Message |
|--------|------------|---------|
| 429 | `over_email_send_rate_limit` | Email rate limit exceeded |

---

### 5. Update Password

**SDK Method**: `supabase.auth.updateUser()`

**Request** (requires valid session from password reset link):
```json
{
  "password": "NewSecurePass456"
}
```

**Success Response** (200):
```json
{
  "id": "uuid-here",
  "email": "employee@company.com",
  "updated_at": "2026-01-08T11:00:00Z"
}
```

**Error Responses**:

| Status | Error Code | Message |
|--------|------------|---------|
| 422 | `weak_password` | Password should be at least 6 characters |
| 422 | `same_password` | New password should be different |

---

### 6. Refresh Session

**SDK Method**: `supabase.auth.refreshSession()` (auto-called by SDK)

**Request**:
```json
{
  "refresh_token": "abc123..."
}
```

**Success Response** (200):
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "refresh_token": "def456...",
  "expires_in": 3600,
  "expires_at": 1704719200,
  "token_type": "bearer"
}
```

Note: Refresh token is rotated (old token invalidated).

---

## Profile Endpoints

### 7. Get Profile

**SDK Method**: `supabase.from('employee_profiles').select().eq('id', userId).single()`

**Request**: GET with RLS (user can only fetch own profile)

**Success Response** (200):
```json
{
  "id": "uuid-here",
  "email": "employee@company.com",
  "full_name": "John Doe",
  "employee_id": "EMP001",
  "status": "active",
  "privacy_consent_at": "2026-01-08T10:10:00Z",
  "created_at": "2026-01-08T10:00:00Z",
  "updated_at": "2026-01-08T10:10:00Z"
}
```

**Error Responses**:

| Status | Error Code | Message |
|--------|------------|---------|
| 404 | - | Profile not found |
| 401 | - | Unauthorized |

---

### 8. Update Profile

**SDK Method**: `supabase.from('employee_profiles').update(data).eq('id', userId)`

**Request**:
```json
{
  "full_name": "John Smith"
}
```

**Allowed Fields**:
- `full_name` - Display name (string, max 255 chars)
- `employee_id` - Company ID (string, max 50 chars)

**Restricted Fields** (cannot update via this endpoint):
- `email` - Requires Supabase Auth email change flow
- `status` - Admin only
- `privacy_consent_at` - Set via separate consent flow

**Success Response** (200):
```json
{
  "id": "uuid-here",
  "email": "employee@company.com",
  "full_name": "John Smith",
  "employee_id": "EMP001",
  "status": "active",
  "privacy_consent_at": "2026-01-08T10:10:00Z",
  "created_at": "2026-01-08T10:00:00Z",
  "updated_at": "2026-01-08T12:00:00Z"
}
```

---

## Auth State Events

The `supabase.auth.onAuthStateChange` stream emits these events:

| Event | When Triggered | Action |
|-------|----------------|--------|
| `signedIn` | Successful sign in or sign up | Navigate to home |
| `signedOut` | User signed out | Navigate to sign in |
| `passwordRecovery` | User clicked password reset link | Show password update UI |
| `tokenRefreshed` | Access token auto-refreshed | Update local session |
| `userUpdated` | User profile changed | Refresh profile data |

---

## Error Response Format

All Supabase Auth errors follow this format:

```json
{
  "error": "error_code",
  "error_description": "Human readable message",
  "status": 400
}
```

In Flutter, catch as `AuthException`:
```dart
try {
  await supabase.auth.signInWithPassword(...);
} on AuthException catch (e) {
  print(e.message);    // Human readable
  print(e.statusCode); // HTTP status as string
}
```

---

## Rate Limits Reference

| Operation | Limit | Reset Window |
|-----------|-------|--------------|
| Sign up emails | 2/hour | Hourly |
| Password reset emails | 2/hour | Hourly |
| Sign in attempts | 30/hour | Hourly |
| Token refresh | 1800/hour | Hourly |

Note: Limits configurable in Supabase Dashboard or via custom SMTP.
