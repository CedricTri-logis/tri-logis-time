# Supabase RPC Contracts: Cleaning Session Tracking

## scan_in

Start a cleaning session for an employee at a studio.

**Parameters**:
```
p_employee_id  UUID      -- The authenticated employee
p_qr_code      TEXT      -- The scanned QR code string
p_shift_id     UUID      -- The employee's active shift
```

**Returns**: JSON
```json
{
  "success": true,
  "session_id": "uuid",
  "studio": {
    "id": "uuid",
    "studio_number": "201",
    "building_name": "Le Citadin",
    "studio_type": "unit"
  },
  "started_at": "2026-02-12T09:30:00Z"
}
```

**Error cases**:
```json
{ "success": false, "error": "INVALID_QR_CODE", "message": "QR code not found" }
{ "success": false, "error": "STUDIO_INACTIVE", "message": "Studio is no longer active" }
{ "success": false, "error": "NO_ACTIVE_SHIFT", "message": "No active shift found" }
{ "success": false, "error": "SESSION_EXISTS", "message": "Active session already exists for this studio", "existing_session_id": "uuid" }
```

**Logic**:
1. Validate QR code exists in `studios` table and `is_active = true`
2. Validate shift exists and is active
3. Check if employee already has an active session for this studio → return error with existing session
4. Insert new `cleaning_sessions` row with status `in_progress`
5. Return session details with studio info

---

## scan_out

Complete a cleaning session when employee scans out.

**Parameters**:
```
p_employee_id  UUID      -- The authenticated employee
p_qr_code      TEXT      -- The scanned QR code string
```

**Returns**: JSON
```json
{
  "success": true,
  "session_id": "uuid",
  "studio": {
    "id": "uuid",
    "studio_number": "201",
    "building_name": "Le Citadin",
    "studio_type": "unit"
  },
  "started_at": "2026-02-12T09:30:00Z",
  "completed_at": "2026-02-12T10:15:00Z",
  "duration_minutes": 45.0,
  "is_flagged": false
}
```

**Error cases**:
```json
{ "success": false, "error": "INVALID_QR_CODE", "message": "QR code not found" }
{ "success": false, "error": "NO_ACTIVE_SESSION", "message": "No active cleaning session for this studio" }
```

**Logic**:
1. Look up studio by QR code
2. Find active session for this employee + studio
3. Set `completed_at = now()`, compute `duration_minutes`
4. Apply flagging rules based on studio_type and duration
5. Set status to `completed`
6. Return session details

---

## auto_close_shift_sessions

Auto-close all open cleaning sessions when a shift ends.

**Parameters**:
```
p_shift_id       UUID          -- The shift being closed
p_employee_id    UUID          -- The employee
p_closed_at      TIMESTAMPTZ   -- The shift clock-out timestamp
```

**Returns**: JSON
```json
{
  "closed_count": 2,
  "sessions": [
    { "session_id": "uuid", "studio_number": "201", "duration_minutes": 45.0 },
    { "session_id": "uuid", "studio_number": "202", "duration_minutes": 120.5 }
  ]
}
```

**Logic**:
1. Find all `in_progress` sessions for the given shift_id and employee_id
2. Set `completed_at = p_closed_at`, compute duration
3. Set status to `auto_closed`
4. Apply flagging rules
5. Return count and details

---

## get_cleaning_dashboard

Get cleaning activity summary for supervisor dashboard.

**Parameters**:
```
p_building_id    UUID          -- Filter by building (NULL for all)
p_employee_id    UUID          -- Filter by employee (NULL for all)
p_date_from      DATE          -- Start date
p_date_to        DATE          -- End date
p_limit          INTEGER       -- Pagination limit (default 50)
p_offset         INTEGER       -- Pagination offset (default 0)
```

**Returns**: JSON
```json
{
  "summary": {
    "total_sessions": 45,
    "completed": 40,
    "in_progress": 3,
    "auto_closed": 2,
    "avg_duration_minutes": 38.5,
    "flagged_count": 4
  },
  "sessions": [
    {
      "id": "uuid",
      "employee_name": "Jean Dupont",
      "studio_number": "201",
      "building_name": "Le Citadin",
      "studio_type": "unit",
      "status": "completed",
      "started_at": "2026-02-12T09:30:00Z",
      "completed_at": "2026-02-12T10:15:00Z",
      "duration_minutes": 45.0,
      "is_flagged": false
    }
  ],
  "total_count": 45
}
```

**Logic**:
1. Join cleaning_sessions + studios + buildings + employee_profiles
2. Apply filters (building, employee, date range)
3. RLS enforcement: supervisors see only their supervised employees
4. Compute summary aggregates
5. Return paginated sessions + summary

---

## get_cleaning_stats_by_building

Get per-building cleaning statistics.

**Parameters**:
```
p_date_from      DATE          -- Start date
p_date_to        DATE          -- End date
```

**Returns**: JSON array
```json
[
  {
    "building_id": "uuid",
    "building_name": "Le Citadin",
    "total_studios": 11,
    "cleaned_today": 8,
    "in_progress": 1,
    "not_started": 2,
    "avg_duration_minutes": 35.2
  }
]
```

---

## get_employee_cleaning_stats

Get per-employee cleaning performance.

**Parameters**:
```
p_employee_id    UUID          -- Specific employee (NULL for all supervised)
p_date_from      DATE          -- Start date
p_date_to        DATE          -- End date
```

**Returns**: JSON
```json
{
  "employee_name": "Jean Dupont",
  "total_sessions": 120,
  "avg_duration_minutes": 38.5,
  "sessions_by_building": [
    { "building_name": "Le Citadin", "count": 45, "avg_duration": 35.2 },
    { "building_name": "Le Cardinal", "count": 30, "avg_duration": 42.1 }
  ],
  "flagged_sessions": 3
}
```

---

## manually_close_session

Allow supervisor to close an orphaned session.

**Parameters**:
```
p_session_id     UUID          -- The session to close
p_closed_by      UUID          -- The supervisor performing the action
```

**Returns**: JSON
```json
{
  "success": true,
  "session_id": "uuid",
  "status": "manually_closed",
  "duration_minutes": 120.5
}
```

**Logic**:
1. Verify session exists and is `in_progress`
2. Verify caller has supervisor access
3. Set `completed_at = now()`, status = `manually_closed`
4. Compute duration and apply flagging
5. Return result

---

## get_active_session

Get the current active cleaning session for an employee (if any).

**Parameters**:
```
p_employee_id    UUID
```

**Returns**: JSON (null if no active session)
```json
{
  "session_id": "uuid",
  "studio": {
    "id": "uuid",
    "studio_number": "201",
    "building_name": "Le Citadin",
    "studio_type": "unit"
  },
  "started_at": "2026-02-12T09:30:00Z"
}
```
