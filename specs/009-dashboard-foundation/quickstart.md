# Quickstart: Dashboard Foundation

**Date**: 2026-01-15 | **Spec**: 009-dashboard-foundation

## Prerequisites

- Node.js 18.x LTS
- pnpm (recommended) or npm
- Supabase project with existing schema (migrations 001-009 applied)
- Admin or super_admin user account for testing

## Project Setup

### 1. Create Next.js Project

```bash
# From repository root
pnpm create next-app dashboard --typescript --tailwind --eslint --app --src-dir --import-alias "@/*"
cd dashboard
```

### 2. Install Dependencies

```bash
# Core dependencies
pnpm add @refinedev/core @refinedev/nextjs-router @refinedev/supabase
pnpm add @supabase/ssr @supabase/supabase-js
pnpm add @tanstack/react-table
pnpm add zod lucide-react

# Dev dependencies
pnpm add -D @playwright/test
```

### 3. Initialize shadcn/ui

```bash
pnpm dlx shadcn@latest init

# Select options:
# - Style: Default
# - Base color: Slate
# - CSS variables: Yes

# Add required components
pnpm dlx shadcn@latest add card table badge button skeleton dropdown-menu select
```

### 4. Environment Configuration

Create `.env.local`:
```env
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

## Project Structure

After setup, create the following structure:

```
dashboard/
├── src/
│   ├── app/
│   │   ├── layout.tsx              # Root layout with Refine
│   │   ├── page.tsx                # Redirect to /dashboard
│   │   ├── login/
│   │   │   └── page.tsx            # Login page
│   │   └── dashboard/
│   │       ├── layout.tsx          # Dashboard shell
│   │       ├── page.tsx            # Organization overview
│   │       └── teams/
│   │           └── page.tsx        # Team comparison
│   ├── components/
│   │   ├── ui/                     # shadcn/ui components
│   │   ├── dashboard/
│   │   │   ├── stats-cards.tsx
│   │   │   ├── activity-feed.tsx
│   │   │   ├── team-comparison-table.tsx
│   │   │   └── data-freshness.tsx
│   │   └── layout/
│   │       ├── sidebar.tsx
│   │       └── header.tsx
│   ├── lib/
│   │   ├── supabase/
│   │   │   ├── client.ts
│   │   │   └── server.ts
│   │   ├── providers/
│   │   │   ├── auth-provider.ts
│   │   │   └── data-provider.ts
│   │   └── utils.ts
│   └── types/
│       └── dashboard.ts
├── tests/
│   └── e2e/
│       └── dashboard.spec.ts
├── .env.local
└── middleware.ts
```

## Key File Templates

### src/lib/supabase/client.ts

```typescript
'use client';

import { createBrowserClient } from '@supabase/ssr';

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}

// Singleton for use with Refine
export const supabaseClient = createClient();
```

### src/lib/providers/data-provider.ts

```typescript
import { dataProvider as supabaseDataProvider } from '@refinedev/supabase';
import { DataProvider } from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';

const baseDataProvider = supabaseDataProvider(supabaseClient);

export const dataProvider: DataProvider = {
  ...baseDataProvider,

  custom: async ({ meta, payload }) => {
    // Support RPC calls via meta.rpc
    if (meta?.rpc) {
      const { data, error } = await supabaseClient.rpc(meta.rpc, payload ?? {});
      if (error) throw error;
      return { data };
    }
    return baseDataProvider.custom?.({ meta, payload }) ?? { data: [] };
  },
};
```

### middleware.ts (root)

```typescript
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          cookiesToSet.forEach(({ name, value, options }) => {
            request.cookies.set(name, value);
            response.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  const { data: { user } } = await supabase.auth.getUser();

  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');
  const isLoginPage = request.nextUrl.pathname === '/login';

  if (isProtected && !user) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  if (isLoginPage && user) {
    return NextResponse.redirect(new URL('/dashboard', request.url));
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)'],
};
```

## Development Commands

```bash
# Start development server
pnpm dev

# Build for production
pnpm build

# Run E2E tests
pnpm exec playwright test

# Generate Supabase types (from repo root)
cd ../supabase && supabase gen types typescript --local > ../dashboard/src/types/database.ts
```

## Database Migration

Before using the dashboard, apply the new migration:

```bash
# From repository root
cd supabase
supabase migration new dashboard_aggregations

# Add the RPC functions from data-model.md to the migration file
# Then apply:
supabase db push
```

## Testing Checklist

- [ ] Login with admin account succeeds
- [ ] Login with non-admin account redirects away from dashboard
- [ ] Organization stats display correctly
- [ ] Activity feed shows active employees
- [ ] Team comparison table loads all managers
- [ ] Date range filter updates team metrics
- [ ] 30-second auto-refresh works
- [ ] Manual refresh button works
- [ ] Data freshness indicator shows correct age
- [ ] Navigation to manager's team detail works

## Deployment

### Vercel Deployment

1. Connect repository to Vercel
2. Set root directory to `dashboard`
3. Add environment variables:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
4. Deploy

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL | Yes |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase publishable key | Yes |

## Troubleshooting

### "Access denied" on dashboard
- Verify user has `admin` or `super_admin` role in `employee_profiles`
- Check RLS policies are applied correctly

### Auth not persisting
- Ensure middleware is in project root (not src/)
- Check cookies are being set (browser dev tools)

### RPC function not found
- Apply migration: `supabase db push`
- Verify function name matches exactly

### Data not refreshing
- Check `refetchInterval` is set in query options
- Verify `refetchIntervalInBackground: true` for inactive tabs
