# API Contracts: Dashboard Foundation

**Date**: 2026-01-15 | **Spec**: 009-dashboard-foundation

## Overview

The Dashboard Foundation uses Supabase RPC functions for server-side data aggregation. All endpoints require admin/super_admin authentication.

## Authentication

All dashboard API calls require:
1. Valid Supabase session (JWT in Authorization header)
2. User with `admin` or `super_admin` role in `employee_profiles`

Failed auth returns:
```json
{
  "error": {
    "code": "PGRST301",
    "message": "Access denied: admin or super_admin role required"
  }
}
```

---

## RPC Endpoints

### GET Organization Dashboard Summary

**Supabase Call**: `supabaseClient.rpc('get_org_dashboard_summary')`

**Parameters**: None

**Response** (200 OK):
```typescript
{
  employee_counts: {
    total: number;
    by_role: {
      employee: number;
      manager: number;
      admin: number;
      super_admin: number;
    };
    active_status: {
      active: number;
      inactive: number;
      suspended: number;
    };
  };
  shift_stats: {
    active_shifts: number;
    completed_today: number;
    total_hours_today: number;        // Decimal hours (e.g., 42.5)
    total_hours_this_week: number;
    total_hours_this_month: number;
  };
  generated_at: string;  // ISO 8601 timestamp
}
```

**Example Response**:
```json
{
  "employee_counts": {
    "total": 156,
    "by_role": {
      "employee": 140,
      "manager": 12,
      "admin": 3,
      "super_admin": 1
    },
    "active_status": {
      "active": 152,
      "inactive": 3,
      "suspended": 1
    }
  },
  "shift_stats": {
    "active_shifts": 23,
    "completed_today": 45,
    "total_hours_today": 284.5,
    "total_hours_this_week": 1203.75,
    "total_hours_this_month": 4812.25
  },
  "generated_at": "2026-01-15T14:32:00.123Z"
}
```

**Errors**:
| Code | Message | Cause |
|------|---------|-------|
| 401 | Not authenticated | Missing or invalid session |
| 403 | Access denied | User role is not admin/super_admin |

---

### GET Manager Team Summaries

**Supabase Call**: `supabaseClient.rpc('get_manager_team_summaries', { p_start_date, p_end_date })`

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `p_start_date` | ISO timestamp | No | First day of current month | Period start |
| `p_end_date` | ISO timestamp | No | Now | Period end |

**Response** (200 OK):
```typescript
Array<{
  manager_id: string;          // UUID
  manager_name: string;
  manager_email: string;
  team_size: number;
  active_employees: number;    // Currently clocked in
  total_hours: number;         // Decimal hours
  total_shifts: number;
  avg_hours_per_employee: number;
}>
```

**Example Response**:
```json
[
  {
    "manager_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "manager_name": "Sarah Johnson",
    "manager_email": "sarah@company.com",
    "team_size": 15,
    "active_employees": 8,
    "total_hours": 523.5,
    "total_shifts": 178,
    "avg_hours_per_employee": 34.9
  },
  {
    "manager_id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
    "manager_name": "Mike Chen",
    "manager_email": "mike@company.com",
    "team_size": 12,
    "active_employees": 5,
    "total_hours": 412.25,
    "total_shifts": 142,
    "avg_hours_per_employee": 34.35
  }
]
```

**Example Call**:
```typescript
const { data, error } = await supabaseClient.rpc('get_manager_team_summaries', {
  p_start_date: '2026-01-01T00:00:00Z',
  p_end_date: '2026-01-15T23:59:59Z'
});
```

---

### GET Team Active Status (Existing - From Spec 008)

**Supabase Call**: `supabaseClient.rpc('get_team_active_status')`

**Parameters**: None (returns all employees for admin/super_admin)

**Response** (200 OK):
```typescript
Array<{
  employee_id: string;
  display_name: string;
  email: string;
  employee_number: string | null;
  is_active: boolean;
  current_shift_started_at: string | null;  // ISO timestamp
  today_hours_seconds: number;
  monthly_hours_seconds: number;
  monthly_shift_count: number;
}>
```

**Sorting**: Active employees first (`is_active DESC`), then by name

---

### GET Team Statistics (Existing - From Spec 006, Enhanced in 009)

**Supabase Call**: `supabaseClient.rpc('get_team_statistics', { p_start_date, p_end_date })`

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `p_start_date` | ISO timestamp | No | 30 days ago | Period start |
| `p_end_date` | ISO timestamp | No | Now | Period end |

**Response** (200 OK):
```typescript
{
  total_employees: number;
  total_shifts: number;
  total_seconds: number;
  avg_duration_seconds: number;
  avg_shifts_per_employee: number;
}
```

**Note**: For admin/super_admin, returns organization-wide statistics.

---

## Client Integration Patterns

### Refine useCustom Hook

```typescript
// Dashboard stats with 30-second polling
const { data, isLoading, refetch } = useCustom({
  url: '',
  method: 'get',
  meta: { rpc: 'get_org_dashboard_summary' },
  queryOptions: {
    refetchInterval: 30000,
    refetchIntervalInBackground: true,
    staleTime: 25000,
  },
});
```

### Team Comparison with Date Range

```typescript
const [dateRange, setDateRange] = useState<DateRange>({
  preset: 'this_month'
});

const { data: teams } = useCustom({
  url: '',
  method: 'get',
  config: {
    payload: {
      p_start_date: getStartDate(dateRange),
      p_end_date: getEndDate(dateRange),
    },
  },
  meta: { rpc: 'get_manager_team_summaries' },
  queryOptions: {
    refetchInterval: 30000,
  },
});
```

### Activity Feed

```typescript
const { data: activeEmployees } = useCustom({
  url: '',
  method: 'get',
  meta: { rpc: 'get_team_active_status' },
  queryOptions: {
    refetchInterval: 30000,
    select: (data) => data.filter(e => e.is_active), // Only active
  },
});
```

---

## Error Handling

### Standard Error Response

```typescript
interface SupabaseError {
  code: string;
  message: string;
  details?: string;
  hint?: string;
}
```

### Common Error Codes

| Code | HTTP Status | Meaning |
|------|-------------|---------|
| `PGRST301` | 401 | JWT invalid or expired |
| `PGRST302` | 403 | RLS policy violation |
| `P0001` | 400 | Custom exception from function |
| `42501` | 403 | Insufficient privilege |

### Client Error Handling

```typescript
const { data, error } = await supabaseClient.rpc('get_org_dashboard_summary');

if (error) {
  if (error.code === 'PGRST301') {
    // Redirect to login
    router.push('/login');
  } else if (error.code === '42501' || error.message.includes('Access denied')) {
    // Show unauthorized message
    toast.error('You do not have permission to view this dashboard');
  } else {
    // Generic error
    toast.error('Failed to load dashboard data');
  }
}
```

---

## Rate Limiting

No explicit rate limiting on Supabase RPC calls, but:
- 30-second polling interval prevents excessive requests
- Background refetch pauses when tab is hidden (configurable)
- Manual refresh has UI debouncing (1 second)
