# Data Model: Employee Authentication

**Feature Branch**: `002-employee-auth`
**Date**: 2026-01-08

## Overview

This document defines the data entities for the Employee Authentication feature. Most entities leverage Supabase Auth's built-in user management; the `employee_profiles` table (created in 001-project-foundation) extends the base auth.users with app-specific data.

---

## Entities

### 1. Employee Profile

**Table**: `employee_profiles` (exists from 001_initial_schema.sql)

Extends Supabase Auth `auth.users` with application-specific employee data.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | UUID | PK, FK → auth.users(id), CASCADE DELETE | Matches Supabase Auth user ID |
| `email` | TEXT | UNIQUE, NOT NULL | Employee email (synced from auth.users) |
| `full_name` | TEXT | NULLABLE | Employee display name |
| `employee_id` | TEXT | NULLABLE | Company employee identifier |
| `status` | TEXT | NOT NULL, DEFAULT 'active' | Account status: active, inactive, suspended |
| `privacy_consent_at` | TIMESTAMPTZ | NULLABLE | Required before GPS tracking |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Account creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last profile update |

**Status Values**:
- `active` - Employee can use all app features
- `inactive` - Account deactivated by admin (cannot sign in)
- `suspended` - Temporarily restricted access

**Validation Rules**:
- Email must be valid format (Supabase Auth validates)
- Status must be one of: active, inactive, suspended
- full_name max length: 255 characters (app-level validation)
- employee_id max length: 50 characters (app-level validation)

**RLS Policies** (exist from 001_initial_schema.sql):
- Users can view their own profile
- Users can update their own profile

**Trigger** (exists):
- Auto-creates employee_profile when new user signs up in auth.users

---

### 2. Authentication Session

**Managed By**: Supabase Auth (not custom table)

Represents an active authenticated session.

| Field | Type | Description |
|-------|------|-------------|
| `access_token` | JWT | Short-lived token for API requests (1 hour default) |
| `refresh_token` | String | Long-lived token for session renewal |
| `expires_at` | Timestamp | When access token expires |
| `expires_in` | Integer | Seconds until expiration |
| `token_type` | String | Always "bearer" |
| `user` | User | The authenticated user object |

**Session Behavior**:
- Persisted automatically by supabase_flutter in flutter_secure_storage
- Access token refreshes automatically in background
- Refresh token can only be used once (rotated on each refresh)
- Session survives app restarts

**Token Lifecycle**:
```
Sign In → Session Created → Access Token (1hr) → Auto Refresh → New Token
                              ↓
                         Token Expired + Offline → Session Still Valid Locally
                              ↓
                         Online Again → Refresh Attempted
```

---

### 3. Password Reset Request

**Managed By**: Supabase Auth (not custom table)

Temporary record for password recovery flow.

| Field | Type | Description |
|-------|------|-------------|
| `email` | String | Email address requesting reset |
| `token` | String | One-time reset token (in magic link) |
| `expires_at` | Timestamp | Token expiration (typically 1 hour) |

**Flow**:
1. User requests reset → Email sent with magic link
2. User clicks link → App receives `passwordRecovery` auth event
3. User enters new password → `updateUser()` called
4. Token invalidated

---

## Flutter Data Models

### EmployeeProfile Model

```dart
// lib/features/auth/models/employee_profile.dart

import 'package:flutter/foundation.dart';

@immutable
class EmployeeProfile {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final EmployeeStatus status;
  final DateTime? privacyConsentAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const EmployeeProfile({
    required this.id,
    required this.email,
    this.fullName,
    this.employeeId,
    required this.status,
    this.privacyConsentAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) {
    return EmployeeProfile(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      status: EmployeeStatus.fromString(json['status'] as String),
      privacyConsentAt: json['privacy_consent_at'] != null
          ? DateTime.parse(json['privacy_consent_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'full_name': fullName,
      'employee_id': employeeId,
      'status': status.value,
      'privacy_consent_at': privacyConsentAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  EmployeeProfile copyWith({
    String? fullName,
    String? employeeId,
    EmployeeStatus? status,
    DateTime? privacyConsentAt,
  }) {
    return EmployeeProfile(
      id: id,
      email: email,
      fullName: fullName ?? this.fullName,
      employeeId: employeeId ?? this.employeeId,
      status: status ?? this.status,
      privacyConsentAt: privacyConsentAt ?? this.privacyConsentAt,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  bool get hasPrivacyConsent => privacyConsentAt != null;
  bool get isActive => status == EmployeeStatus.active;
}

enum EmployeeStatus {
  active('active'),
  inactive('inactive'),
  suspended('suspended');

  final String value;
  const EmployeeStatus(this.value);

  static EmployeeStatus fromString(String value) {
    return EmployeeStatus.values.firstWhere(
      (e) => e.value == value,
      orElse: () => EmployeeStatus.active,
    );
  }
}
```

---

## State Transitions

### Employee Status Transitions

```
              ┌──────────────────────┐
              │      (Sign Up)       │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │       active         │
              │  (default state)     │
              └──────────┬───────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          ▼              ▼              │
   ┌─────────────┐ ┌─────────────┐      │
   │  inactive   │ │  suspended  │      │
   │ (admin)     │ │ (admin)     │      │
   └──────┬──────┘ └──────┬──────┘      │
          │               │             │
          └───────────────┴─────────────┘
                (admin reactivates)
```

**Transition Rules**:
- Only admins can change status (not self-service)
- Inactive users cannot sign in (Supabase Auth disabled)
- Suspended users can sign in but see restricted access message

### Authentication State Transitions

```
              ┌──────────────────────┐
              │   unauthenticated    │
              │   (app start)        │
              └──────────┬───────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          ▼              ▼              │
   ┌─────────────┐ ┌─────────────┐      │
   │  Sign In    │ │  Sign Up    │      │
   │             │ │ (verify)    │      │
   └──────┬──────┘ └──────┬──────┘      │
          │               │             │
          └───────┬───────┘             │
                  │                     │
                  ▼                     │
       ┌──────────────────────┐         │
       │    authenticated     │         │
       │  (session active)    │         │
       └──────────┬───────────┘         │
                  │                     │
                  ▼                     │
       ┌──────────────────────┐         │
       │      Sign Out        │─────────┘
       └──────────────────────┘
```

---

## Relationships

```
auth.users (Supabase managed)
    │
    │ 1:1 (created via trigger on signup)
    │
    ▼
employee_profiles
    │
    │ 1:N
    │
    ├──► shifts (already defined in 001)
    │
    └──► gps_points (already defined in 001)
```

---

## Indexes

**Existing** (from 001_initial_schema.sql):
- `idx_employee_profiles_email` - Email lookup for auth
- `idx_employee_profiles_status` - Filter by status

**No additional indexes needed** for authentication feature.

---

## Security Considerations

1. **Password Storage**: Handled by Supabase Auth (bcrypt hashing)
2. **Session Storage**: flutter_secure_storage (encrypted on device)
3. **RLS Enforcement**: Users can only access their own profile
4. **Email Verification**: Required before full access (Supabase Auth setting)
5. **Rate Limiting**: Supabase Auth + client-side throttling
