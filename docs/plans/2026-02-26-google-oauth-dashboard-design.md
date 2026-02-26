# Google OAuth + Login Error Messages — Dashboard

**Date:** 2026-02-26
**Status:** Approved

## Goal

Add Google OAuth as an alternative login method on the dashboard (`/login`) and fix missing error messages on failed email/password login.

## Current State

- Dashboard: Next.js 16 + Refine + Supabase SSR, email/password login only
- Supabase config.toml: Google OAuth listed but `enabled = false`
- Middleware checks `employee_profiles.role` for `admin`/`super_admin`
- Site URL: `https://time.trilogis.ca`
- Login errors are not displayed to the user

## Design

### Google OAuth Flow

1. User clicks "Se connecter avec Google" on login page
2. Supabase redirects to Google OAuth (restricted to `@trilogis.ca` via `hd` parameter)
3. Google authenticates → callback to `/auth/callback`
4. Existing middleware checks `admin`/`super_admin` role in `employee_profiles`
5. No profile or insufficient role → redirected to `/login?error=unauthorized`

### Constraints

- Domain restricted to `@trilogis.ca`
- User MUST already exist in `employee_profiles` with admin/super_admin role
- No account linking (Google and email/password are separate Supabase auth users)
- No changes to mobile app
- No new DB migrations

### Changes Required

**Supabase (config):**
- Enable Google OAuth in Supabase console (Client ID + Client Secret from Google Cloud Console)
- Add callback URLs to allowed redirects

**Dashboard files:**

| File | Change |
|------|--------|
| `auth-provider.ts` | Add `signInWithOAuth({ provider: 'google' })` support in `login()` |
| `login/page.tsx` | Add Google button + display error messages for failed login |
| `auth/callback/route.ts` | Extend to handle OAuth callback (not just password reset) |

### Login UI

```
┌─────────────────────────────────┐
│  GPS Tracker Dashboard          │
│  Sign in with your admin        │
│  account to access dashboard    │
├─────────────────────────────────┤
│                                 │
│  [G  Se connecter avec Google]  │
│                                 │
│  ──────── ou ────────           │
│                                 │
│  Email                          │
│  [admin@company.com       ]     │
│                                 │
│  Password                       │
│  [Enter your password     ]     │
│                                 │
│  ⚠ Email ou mot de passe       │
│    incorrect                    │
│                                 │
│  [      Sign In           ]     │
│                                 │
│  Forgot your password?          │
└─────────────────────────────────┘
```

### Security

- `hd` parameter restricts Google OAuth to `@trilogis.ca` domain
- User must pre-exist in `employee_profiles` with admin/super_admin role
- Existing middleware enforces role check — no changes needed

### Out of Scope

- Account linking (Google + email = separate Supabase accounts)
- Mobile app changes
- New roles or DB migrations
