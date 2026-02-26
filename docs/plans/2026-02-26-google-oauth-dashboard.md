# Google OAuth + Login Error Messages — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Google OAuth as an alternative login method on the dashboard and fix missing error messages on failed email/password login.

**Architecture:** Google OAuth uses Supabase's built-in OAuth flow — the dashboard calls `signInWithOAuth`, Supabase handles the Google redirect, and our existing `/auth/callback` route exchanges the code for a session. The existing middleware role check (`admin`/`super_admin`) applies to both login methods. No new DB migrations needed.

**Tech Stack:** Next.js 16, Supabase Auth (OAuth PKCE flow), shadcn/ui, Refine `useLogin` hook

---

### Task 1: Fix login error messages on failed email/password login

**Files:**
- Modify: `dashboard/src/app/login/page.tsx`

**Context:** The auth provider at `dashboard/src/lib/providers/auth-provider.ts:14-22` already returns `{ success: false, error: { name, message } }` on failure. But the login page never reads or displays this error. Refine's `useLogin().mutate()` resolves (not rejects) when auth provider returns `success: false` — the error is in the `onSuccess` callback data.

**Step 1: Add error state and display to LoginForm**

In `dashboard/src/app/login/page.tsx`, add a `loginError` state and wire it to the `login()` mutate callbacks. Display the error inline above the form button.

```tsx
function LoginForm() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [loginError, setLoginError] = useState<string | null>(null);  // ADD
  const { mutate: login } = useLogin();
  const searchParams = useSearchParams();
  const error = searchParams.get('error');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    setLoginError(null);  // ADD: clear previous error
    login({ email, password }, {
      onSettled: () => setIsSubmitting(false),
      onSuccess: (data) => {                           // ADD
        if (!data.success && data.error) {             // ADD
          setLoginError(data.error.message);           // ADD
        }                                              // ADD
      },                                               // ADD
    });
  };
```

Add the error display after the password field, before the submit button:

```tsx
{loginError && (
  <div className="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-600">
    {loginError}
  </div>
)}
```

**Step 2: Verify manually**

1. Go to `http://localhost:3001/login`
2. Enter a valid email with wrong password → should see "Invalid login credentials"
3. Enter a non-existent email → should see error message
4. Enter correct credentials → should redirect to `/dashboard` (no error shown)

**Step 3: Commit**

```bash
git add dashboard/src/app/login/page.tsx
git commit -m "fix: display login error messages on failed email/password auth"
```

---

### Task 2: Update callback route to handle OAuth redirects

**Files:**
- Modify: `dashboard/src/app/auth/callback/route.ts`

**Context:** The current callback route defaults `next` to `/reset-password`. For OAuth logins, we need it to redirect to `/dashboard`. We'll pass `?next=/dashboard` in the OAuth `redirectTo` URL (Task 3), so the callback already reads it correctly. However, we should also change the default fallback from `/reset-password` to `/dashboard` since OAuth is now the primary use of this route.

**Step 1: Update default redirect and add error handling**

```typescript
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const code = searchParams.get('code');
  const next = searchParams.get('next') ?? '/dashboard';

  if (!code) {
    return NextResponse.redirect(
      new URL('/login?error=invalid_reset_link', request.url)
    );
  }

  const redirectTo = new URL(next, request.url);
  const response = NextResponse.redirect(redirectTo);

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!.trim(),
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim(),
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          cookiesToSet.forEach(({ name, value, options }) => {
            response.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(
      new URL('/login?error=invalid_reset_link', request.url)
    );
  }

  return response;
}
```

**Step 2: Verify the password reset flow still works**

1. Go to `/forgot-password`, enter an admin email
2. Check Inbucket (or real email) for the reset link
3. Click the link → should still redirect to `/reset-password`
   (The reset email sends `?next=/reset-password` explicitly, so this still works)

**Step 3: Commit**

```bash
git add dashboard/src/app/auth/callback/route.ts
git commit -m "feat: update auth callback default redirect for OAuth support"
```

---

### Task 3: Add Google OAuth button to login page

**Files:**
- Modify: `dashboard/src/app/login/page.tsx`

**Context:** The Google OAuth flow doesn't go through Refine's `login()` — it calls `supabaseClient.auth.signInWithOAuth()` directly, which redirects the browser to Google. After authentication, Google redirects back through Supabase to our `/auth/callback` route (Task 2), which exchanges the code and redirects to `/dashboard`. The middleware then checks the user's role.

**Step 1: Add Google sign-in handler and button**

Add the import for the Supabase client and a `handleGoogleLogin` function:

```tsx
import { supabaseClient } from '@/lib/supabase/client';
```

Add the handler inside `LoginForm`:

```tsx
const handleGoogleLogin = async () => {
  setLoginError(null);
  await supabaseClient.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: `${window.location.origin}/auth/callback?next=/dashboard`,
      queryParams: {
        hd: 'trilogis.ca',
      },
    },
  });
};
```

Add the Google button and separator inside `<CardContent>`, after the error banner and before the `<form>`:

```tsx
<button
  type="button"
  onClick={handleGoogleLogin}
  className="w-full flex items-center justify-center gap-3 px-4 py-2 border border-slate-300 rounded-md text-sm font-medium text-slate-700 bg-white hover:bg-slate-50 transition-colors"
>
  <svg className="w-5 h-5" viewBox="0 0 24 24">
    <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z" fill="#4285F4"/>
    <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
    <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05"/>
    <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
  </svg>
  Se connecter avec Google
</button>

<div className="relative my-4">
  <div className="absolute inset-0 flex items-center">
    <span className="w-full border-t border-slate-300" />
  </div>
  <div className="relative flex justify-center text-xs uppercase">
    <span className="bg-white px-2 text-slate-500">ou</span>
  </div>
</div>
```

**Step 2: Verify manually (requires Supabase Google OAuth configured — see Task 4)**

1. Go to `http://localhost:3001/login`
2. See the Google button above the email/password form with an "ou" separator
3. Click Google button → redirected to Google sign-in
4. Sign in with a `@trilogis.ca` account that exists in `employee_profiles` → redirected to `/dashboard`
5. Sign in with a `@trilogis.ca` account that does NOT have admin role → see "Access denied" error on login page

**Step 3: Commit**

```bash
git add dashboard/src/app/login/page.tsx
git commit -m "feat: add Google OAuth login button to dashboard"
```

---

### Task 4: Configure Google OAuth in Supabase (manual)

**This task is manual — no code changes.**

**Step 1: Create Google OAuth credentials**

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Select or create a project for Tri-Logis
3. Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
4. Application type: **Web application**
5. Name: `Tri-Logis Dashboard`
6. Authorized redirect URIs — add:
   - `https://xdyzdclwvhkfwbkrdsiz.supabase.co/auth/v1/callback`
7. Copy the **Client ID** and **Client Secret**

**Step 2: Enable Google OAuth in Supabase Dashboard**

1. Go to [Supabase Dashboard](https://supabase.com/dashboard/project/xdyzdclwvhkfwbkrdsiz/auth/providers)
2. Find **Google** in the Auth Providers list
3. Toggle **Enable Sign in with Google**
4. Paste the **Client ID** and **Client Secret**
5. Optionally check **Skip nonce check** if using server-side PKCE flow
6. Save

**Step 3: Add redirect URLs in Supabase**

1. Go to **Authentication → URL Configuration**
2. Add to **Redirect URLs**:
   - `http://localhost:3001/auth/callback` (for local dev)
   - `https://time.trilogis.ca/auth/callback` (already exists)

**Step 4: Verify end-to-end**

1. Go to `http://localhost:3001/login`
2. Click "Se connecter avec Google"
3. Sign in with a `@trilogis.ca` Google account
4. Confirm redirect to `/dashboard` (if user has admin role) or error page (if not)
