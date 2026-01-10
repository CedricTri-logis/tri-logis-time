# API Contracts: Employee & Shift Dashboard

**Feature Branch**: `008-employee-shift-dashboard`
**Date**: 2026-01-10

## Overview

This document defines the API contracts for the dashboard feature. Most operations use existing Supabase RPC functions from Spec 006. New contracts focus on dashboard-specific data aggregation.

---

## Existing RPC Functions (Reused)

### GET /rpc/get_supervised_employees

**Purpose**: Get list of employees supervised by current manager with monthly stats.

**Auth**: Requires authenticated user with manager/admin role.

**Request**: No parameters required (uses auth context).

**Response**:
```json
[
  {
    "id": "uuid",
    "email": "employee@example.com",
    "full_name": "John Doe",
    "employee_id": "EMP001",
    "status": "active",
    "role": "employee",
    "last_shift_at": "2026-01-10T08:00:00Z",
    "total_shifts_this_month": 15,
    "total_hours_this_month": 144000
  }
]
```

**Notes**:
- `total_hours_this_month` is in seconds
- Results sorted by full_name, then email

---

### GET /rpc/get_employee_statistics

**Purpose**: Get aggregated shift statistics for an employee.

**Auth**: Requires authenticated user (own data) or supervision relationship.

**Request**:
```json
{
  "p_employee_id": "uuid",
  "p_start_date": "2026-01-01T00:00:00Z",  // optional
  "p_end_date": "2026-01-10T23:59:59Z"     // optional
}
```

**Response**:
```json
{
  "total_shifts": 15,
  "total_seconds": 144000,
  "avg_duration_seconds": 9600,
  "earliest_shift": "2026-01-02T08:00:00Z",
  "latest_shift": "2026-01-10T08:00:00Z",
  "total_gps_points": 450
}
```

---

### GET /rpc/get_team_statistics

**Purpose**: Get aggregate statistics for manager's supervised team.

**Auth**: Requires authenticated user with manager/admin role.

**Request**:
```json
{
  "p_start_date": "2026-01-01T00:00:00Z",  // optional
  "p_end_date": "2026-01-10T23:59:59Z"     // optional
}
```

**Response**:
```json
{
  "total_employees": 10,
  "total_shifts": 150,
  "total_seconds": 1440000,
  "avg_duration_seconds": 9600,
  "avg_shifts_per_employee": 15.0
}
```

---

### GET /rpc/get_employee_shifts

**Purpose**: Get paginated shift history for an employee.

**Auth**: Requires authenticated user (own data) or supervision relationship.

**Request**:
```json
{
  "p_employee_id": "uuid",
  "p_start_date": "2026-01-03T00:00:00Z",  // optional, 7 days ago for dashboard
  "p_end_date": null,                       // optional
  "p_limit": 50,
  "p_offset": 0
}
```

**Response**:
```json
[
  {
    "id": "uuid",
    "employee_id": "uuid",
    "status": "completed",
    "clocked_in_at": "2026-01-10T08:00:00Z",
    "clock_in_location": {"latitude": 37.7749, "longitude": -122.4194},
    "clock_in_accuracy": 5.0,
    "clocked_out_at": "2026-01-10T17:00:00Z",
    "clock_out_location": {"latitude": 37.7749, "longitude": -122.4194},
    "clock_out_accuracy": 8.0,
    "duration_seconds": 32400,
    "gps_point_count": 108,
    "created_at": "2026-01-10T08:00:00Z"
  }
]
```

---

## New RPC Function Required

### GET /rpc/get_dashboard_summary

**Purpose**: Get optimized dashboard data in single query (reduces round-trips).

**Auth**: Requires authenticated user.

**Request**:
```json
{
  "p_include_recent_shifts": true,
  "p_recent_shifts_limit": 10
}
```

**Response**:
```json
{
  "active_shift": {
    "id": "uuid",
    "clocked_in_at": "2026-01-10T08:00:00Z",
    "clock_in_location": {"latitude": 37.7749, "longitude": -122.4194}
  },
  "today_stats": {
    "completed_shifts": 1,
    "total_seconds": 14400,
    "active_shift_seconds": 3600
  },
  "month_stats": {
    "total_shifts": 15,
    "total_seconds": 144000,
    "avg_duration_seconds": 9600
  },
  "recent_shifts": [
    {
      "id": "uuid",
      "status": "completed",
      "clocked_in_at": "2026-01-09T08:00:00Z",
      "clocked_out_at": "2026-01-09T17:00:00Z",
      "duration_seconds": 32400
    }
  ]
}
```

**SQL Definition**:
```sql
CREATE OR REPLACE FUNCTION get_dashboard_summary(
    p_include_recent_shifts BOOLEAN DEFAULT true,
    p_recent_shifts_limit INT DEFAULT 10
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_active_shift JSONB;
    v_today_stats JSONB;
    v_month_stats JSONB;
    v_recent_shifts JSONB;
    v_today_start TIMESTAMPTZ;
    v_month_start TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('error', 'Not authenticated');
    END IF;

    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

    -- Get active shift
    SELECT jsonb_build_object(
        'id', id,
        'clocked_in_at', clocked_in_at,
        'clock_in_location', clock_in_location
    ) INTO v_active_shift
    FROM shifts
    WHERE employee_id = v_user_id AND status = 'active'
    LIMIT 1;

    -- Get today's stats
    SELECT jsonb_build_object(
        'completed_shifts', COUNT(*) FILTER (WHERE status = 'completed'),
        'total_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'completed'
                THEN clocked_out_at - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0),
        'active_shift_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'active'
                THEN NOW() - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0)
    ) INTO v_today_stats
    FROM shifts
    WHERE employee_id = v_user_id AND clocked_in_at >= v_today_start;

    -- Get month stats
    SELECT jsonb_build_object(
        'total_shifts', COUNT(*) FILTER (WHERE status = 'completed'),
        'total_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'completed'
                THEN clocked_out_at - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0),
        'avg_duration_seconds', CASE
            WHEN COUNT(*) FILTER (WHERE status = 'completed') > 0 THEN
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN status = 'completed'
                        THEN clocked_out_at - clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0) / COUNT(*) FILTER (WHERE status = 'completed')
            ELSE 0
        END
    ) INTO v_month_stats
    FROM shifts
    WHERE employee_id = v_user_id AND clocked_in_at >= v_month_start;

    -- Get recent shifts if requested
    IF p_include_recent_shifts THEN
        SELECT COALESCE(jsonb_agg(shift_row), '[]'::jsonb) INTO v_recent_shifts
        FROM (
            SELECT jsonb_build_object(
                'id', id,
                'status', status,
                'clocked_in_at', clocked_in_at,
                'clocked_out_at', clocked_out_at,
                'duration_seconds', EXTRACT(EPOCH FROM
                    COALESCE(clocked_out_at, NOW()) - clocked_in_at)::INT
            ) as shift_row
            FROM shifts
            WHERE employee_id = v_user_id
            AND clocked_in_at >= NOW() - INTERVAL '7 days'
            ORDER BY clocked_in_at DESC
            LIMIT p_recent_shifts_limit
        ) sub;
    ELSE
        v_recent_shifts := '[]'::jsonb;
    END IF;

    RETURN jsonb_build_object(
        'active_shift', v_active_shift,
        'today_stats', v_today_stats,
        'month_stats', v_month_stats,
        'recent_shifts', v_recent_shifts
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

### GET /rpc/get_team_employee_hours

**Purpose**: Get hours per employee for bar chart visualization.

**Auth**: Requires authenticated user with manager/admin role.

**Request**:
```json
{
  "p_start_date": "2026-01-01T00:00:00Z",
  "p_end_date": "2026-01-10T23:59:59Z"
}
```

**Response**:
```json
[
  {
    "employee_id": "uuid",
    "display_name": "John Doe",
    "total_hours": 45.5
  },
  {
    "employee_id": "uuid",
    "display_name": "Jane Smith",
    "total_hours": 38.0
  }
]
```

**SQL Definition**:
```sql
CREATE OR REPLACE FUNCTION get_team_employee_hours(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    employee_id UUID,
    display_name TEXT,
    total_hours DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ep.id as employee_id,
        COALESCE(ep.full_name, ep.email) as display_name,
        COALESCE(
            ROUND(
                EXTRACT(EPOCH FROM SUM(
                    COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                )) / 3600.0,
                1
            ),
            0
        ) as total_hours
    FROM employee_profiles ep
    INNER JOIN employee_supervisors es ON es.employee_id = ep.id
    LEFT JOIN shifts s ON s.employee_id = ep.id
        AND s.status = 'completed'
        AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
        AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date)
    WHERE es.manager_id = (SELECT auth.uid())
    AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    GROUP BY ep.id, ep.full_name, ep.email
    ORDER BY total_hours DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Local Cache Operations

### Dashboard Cache Table Operations

**Insert/Update Cache**:
```dart
Future<void> cacheDashboardData(String cacheId, String cacheType,
    String employeeId, Map<String, dynamic> data) async {
  final now = DateTime.now().toUtc();
  final expiresAt = now.add(Duration(days: 7));

  await db.insert('dashboard_cache', {
    'id': cacheId,
    'cache_type': cacheType,
    'employee_id': employeeId,
    'cached_data': jsonEncode(data),
    'last_updated': now.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
```

**Read Cache**:
```dart
Future<Map<String, dynamic>?> getCachedDashboard(String cacheId) async {
  final results = await db.query('dashboard_cache',
    where: 'id = ? AND expires_at > ?',
    whereArgs: [cacheId, DateTime.now().toUtc().toIso8601String()],
  );

  if (results.isEmpty) return null;
  return jsonDecode(results.first['cached_data'] as String);
}
```

**Clear Expired Cache**:
```dart
Future<int> clearExpiredCache() async {
  return await db.delete('dashboard_cache',
    where: 'expires_at < ?',
    whereArgs: [DateTime.now().toUtc().toIso8601String()],
  );
}
```

---

## Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `NOT_AUTHENTICATED` | 401 | User not logged in |
| `ACCESS_DENIED` | 403 | No supervision relationship |
| `EMPLOYEE_NOT_FOUND` | 404 | Employee ID doesn't exist |
| `INVALID_DATE_RANGE` | 400 | End date before start date |

---

## Rate Limiting

- Dashboard refresh: Max 1 request per 5 seconds per user
- Team statistics: Max 1 request per 10 seconds per user
- Client should implement debouncing for pull-to-refresh
