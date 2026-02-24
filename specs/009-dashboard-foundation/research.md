# Research: Dashboard Foundation

**Date**: 2026-01-15 | **Spec**: 009-dashboard-foundation

## Research Questions Resolved

### 1. Refine + Supabase Integration for RPC Functions

**Decision**: Extend the default dataProvider to support RPC calls via `meta.rpc` parameter

**Rationale**:
- Default `@refinedev/supabase` dataProvider only supports table CRUD operations
- Dashboard requires aggregated statistics from Supabase RPC functions (e.g., `get_team_statistics`, `get_team_active_status`)
- Extending dataProvider maintains Refine patterns while adding RPC capability

**Alternatives Considered**:
- Direct `supabaseClient.rpc()` calls: Rejected because it bypasses Refine's caching and loading states
- Custom hooks with TanStack Query: Viable but creates inconsistency with Refine patterns

**Implementation Pattern**:
```typescript
// Extended dataProvider
const dataProvider: DataProvider = {
  ...supabaseDataProvider(supabaseClient),
  custom: async ({ meta, payload }) => {
    if (meta?.rpc) {
      const { data, error } = await supabaseClient.rpc(meta.rpc, payload);
      if (error) throw error;
      return { data };
    }
    return baseDataProvider.custom?.({ meta, payload }) ?? { data: [] };
  },
};
```

### 2. Next.js App Router with Refine Configuration

**Decision**: Use `@refinedev/nextjs-router` v7+ with client-side `<Refine />` wrapper

**Rationale**:
- Refine uses React context heavily; must be client component
- v7+ defaults to App Router (not Pages Router)
- Route parameter mapping handled automatically

**File Structure**:
```
app/
├── layout.tsx          # Client component with Refine wrapper
├── login/page.tsx      # Auth page
└── dashboard/
    ├── layout.tsx      # Dashboard shell
    ├── page.tsx        # Organization overview
    └── teams/page.tsx  # Team comparison
```

### 3. Supabase Auth SSR-Safe Patterns

**Decision**: Use `@supabase/ssr` package with middleware for session refresh

**Rationale**:
- Standard `@supabase/supabase-js` auth is not SSR-safe
- `@supabase/ssr` provides cookie-based auth that works across server/client
- Middleware refreshes sessions on each request

**Security Pattern**:
- Always use `supabase.auth.getUser()` (validates with server) not `getSession()` (trusts cookies)
- Middleware checks role before allowing access to `/dashboard` routes
- Auth provider integrates with Refine's `authProvider` interface

### 4. shadcn/ui Dashboard Components

**Decision**: Use shadcn/ui Card, Table, Badge components with TanStack Table for data grids

**Rationale**:
- Constitution mandates shadcn/ui
- Card components suit stats display
- TanStack Table provides sorting, pagination, filtering
- Skeleton components for loading states

**Key Components**:
- `StatsCard` - Displays metrics with icon and trend
- `DataTable` - Employee/team tables with sorting
- `ActivityFeed` - Active employee list with status badges

### 5. 30-Second Auto-Refresh Implementation

**Decision**: Use `queryOptions.refetchInterval` on Refine hooks

**Rationale**:
- Refine uses TanStack Query internally
- Simple configuration: `refetchInterval: 30000`
- `refetchIntervalInBackground: true` continues polling when tab inactive
- Manual refresh available via `refetch()` function

**Pattern**:
```typescript
const { data } = useCustom({
  meta: { rpc: "get_admin_dashboard_stats" },
  queryOptions: {
    refetchInterval: 30000,
    refetchIntervalInBackground: true,
    staleTime: 25000,
  },
});
```

### 6. Existing RPC Functions Analysis

**Decision**: Leverage existing RPC functions from migrations 006-009; add 2 new dashboard-specific RPCs

**Existing Functions (Ready to Use)**:
| Function | Purpose | Dashboard Use |
|----------|---------|---------------|
| `get_all_users()` | List all users (admin/super_admin only) | Employee count by role |
| `get_team_active_status()` | Active shift status per employee | Activity feed |
| `get_team_statistics()` | Aggregate team metrics | Organization-wide totals |
| `get_team_employee_hours()` | Per-employee hours | Team comparison bars |

**New Functions Needed**:
1. `get_org_dashboard_summary()` - Single call for all dashboard stats
2. `get_manager_team_summaries()` - All teams with aggregate metrics for comparison

**Rationale**: New RPCs optimize network calls (single request vs multiple) and enable server-side pagination for large organizations.

### 7. Deployment Strategy

**Decision**: Vercel deployment (separate from Supabase Storage)

**Rationale**:
- Constitution specifies Vercel for dashboard deployment
- Next.js is first-class citizen on Vercel
- Separate deployment allows independent scaling
- Environment variables managed in Vercel dashboard

**Configuration**:
- `NEXT_PUBLIC_SUPABASE_URL` - Project URL
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` - Publishable key
- No service role key in frontend

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `next` | ^14.0.0 | App Router framework |
| `@refinedev/core` | ^4.0.0 | Data/auth/routing orchestration |
| `@refinedev/supabase` | ^6.0.0 | Supabase data provider |
| `@refinedev/nextjs-router` | ^7.0.0 | App Router integration |
| `@supabase/ssr` | ^0.5.0 | SSR-safe auth |
| `@supabase/supabase-js` | ^2.45.0 | Supabase client |
| `@tanstack/react-table` | ^8.0.0 | Data tables |
| `tailwindcss` | ^3.4.0 | Styling |
| `zod` | ^3.23.0 | Schema validation |
| `lucide-react` | ^0.400.0 | Icons |
| Playwright | ^1.45.0 | E2E testing |

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| RPC functions returning large datasets | Server-side pagination in new RPC functions |
| Auth token expiry during long sessions | Middleware refreshes session on each request |
| Browser tab inactive missing updates | `refetchIntervalInBackground: true` continues polling |
| Slow initial load | React Query caching + skeleton loading states |

## Performance Targets

| Metric | Target | Approach |
|--------|--------|----------|
| Dashboard initial load | <3s | Single RPC call for all stats |
| Team comparison load | <2s | Paginated RPC with limit 50 |
| 1000 employee support | No degradation | Server-side aggregation + pagination |
| Data freshness | 30s precision | Auto-refresh interval |
