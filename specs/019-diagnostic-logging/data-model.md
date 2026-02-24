# Data Model: 019-diagnostic-logging

**Date**: 2026-02-24

## Entities

### 1. DiagnosticEvent (Local - SQLCipher)

Represents a single diagnostic event captured on the device.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | TEXT (UUID) | PRIMARY KEY | Client-generated UUID for deduplication |
| `employee_id` | TEXT (UUID) | NOT NULL | Employee who generated the event |
| `shift_id` | TEXT (UUID) | NULLABLE | Active shift ID (null for non-shift events) |
| `device_id` | TEXT | NOT NULL | Persistent device identifier |
| `event_category` | TEXT | NOT NULL, CHECK | One of: gps, shift, sync, auth, permission, lifecycle, thermal, error, network |
| `severity` | TEXT | NOT NULL, CHECK | One of: debug, info, warn, error, critical |
| `message` | TEXT | NOT NULL | Human-readable event description |
| `metadata` | TEXT (JSON) | NULLABLE | Structured event-specific data |
| `app_version` | TEXT | NOT NULL | App version string (e.g., "1.0.0+52") |
| `platform` | TEXT | NOT NULL | "ios" or "android" |
| `os_version` | TEXT | NULLABLE | OS version string |
| `sync_status` | TEXT | NOT NULL, DEFAULT 'pending' | 'pending' or 'synced' |
| `created_at` | TEXT (ISO8601) | NOT NULL | UTC timestamp of event creation |

**Indexes:**
- `idx_diag_sync_status` ON (sync_status) — for efficient pending query
- `idx_diag_created_at` ON (created_at) — for pruning old records
- `idx_diag_category_severity` ON (event_category, severity) — for local filtering

**Constraints:**
- `event_category` CHECK IN ('gps', 'shift', 'sync', 'auth', 'permission', 'lifecycle', 'thermal', 'error', 'network')
- `severity` CHECK IN ('debug', 'info', 'warn', 'error', 'critical')
- `sync_status` CHECK IN ('pending', 'synced')

**Storage limits:**
- Max 5000 rows
- Pruning: delete oldest synced events when limit exceeded
- Estimated size: 5000 × ~400 bytes = ~2MB

---

### 2. diagnostic_logs (Server - Supabase PostgreSQL)

Server-side table receiving synced diagnostic events from all devices.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY | Client-generated UUID (deduplication key) |
| `employee_id` | UUID | NOT NULL, FK → auth.users | Employee who generated the event |
| `shift_id` | UUID | NULLABLE | Shift context (may reference shifts.id) |
| `device_id` | TEXT | NOT NULL | Device identifier |
| `event_category` | TEXT | NOT NULL | Event category |
| `severity` | TEXT | NOT NULL | Event severity |
| `message` | TEXT | NOT NULL | Human-readable description |
| `metadata` | JSONB | NULLABLE | Structured event-specific data |
| `app_version` | TEXT | NOT NULL | App version at time of event |
| `platform` | TEXT | NOT NULL | ios or android |
| `os_version` | TEXT | NULLABLE | OS version string |
| `created_at` | TIMESTAMPTZ | NOT NULL | Event timestamp (device clock) |
| `received_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Server receive timestamp |

**Indexes:**
- `idx_diag_logs_employee` ON (employee_id, created_at DESC) — per-employee timeline
- `idx_diag_logs_shift` ON (shift_id) WHERE shift_id IS NOT NULL — per-shift events
- `idx_diag_logs_category` ON (event_category, severity) — filtering by type
- `idx_diag_logs_created` ON (created_at DESC) — global timeline

**RLS Policies:**
- INSERT: `auth.uid() = employee_id` (employees can only insert their own logs)
- SELECT: Admins/managers can read all logs (via `employee_profiles.role IN ('admin', 'manager')` or supervisor relationship)

**Retention:**
- pg_cron job: DELETE WHERE created_at < NOW() - INTERVAL '90 days' (runs daily at 3am)

---

## Entity Relationships

```
employee_profiles (existing)
  ├── 1:N → diagnostic_logs (employee_id)
  └── 1:N → shifts (existing)
                └── 1:N → diagnostic_logs (shift_id, optional)
```

## State Transitions

### DiagnosticEvent.sync_status
```
pending → synced    (successful server sync)
pending → [deleted] (pruned when storage limit exceeded and already synced)
```

Note: Unlike GPS points, diagnostic events are never quarantined — if sync fails, they remain pending and retry. Old synced events are pruned for storage management.

## Event Category Schema

### GPS Events (`event_category: 'gps'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `tracking_started` | info | `{shift_id, config: {active_interval, stationary_interval}}` |
| `tracking_stopped` | info | `{shift_id, total_points, duration_minutes}` |
| `gps_lost` | warn | `{gap_started_at, last_position: {lat, lng, accuracy}, seconds_since_last}` |
| `gps_restored` | info | `{gap_duration_seconds, recovery_method, position: {lat, lng, accuracy}}` |
| `stream_recovery_attempt` | info | `{attempt_number, backoff_minutes, gap_duration_seconds}` |
| `stream_recovered` | info | `{attempt_number, gap_duration_seconds}` |
| `stream_recovery_failing` | warn | `{attempt_count, gap_minutes}` |
| `foreground_service_died` | error | `{detected_at, last_known_alive_at}` |
| `foreground_service_restarted` | info | `{restart_reason}` |
| `significant_location_activated` | info | `{reason: 'gps_lost'}` |
| `significant_location_deactivated` | info | `{reason: 'gps_restored'}` |
| `significant_location_wakeup` | info | `{latitude, longitude, accuracy}` |
| `position_error` | warn | `{error_message}` |
| `gps_gap_self_healing` | info | `{gap_seconds, action: 'recover_stream'}` |
| `point_insert_failed` | error | `{error_message, shift_id}` |

### Shift Events (`event_category: 'shift'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `clock_in_attempt` | info | `{location: {lat, lng, accuracy}}` |
| `clock_in_success` | info | `{shift_id, server_id, duration_ms}` |
| `clock_in_failure` | error | `{error_message, location: {lat, lng}}` |
| `clock_out_attempt` | info | `{shift_id, reason}` |
| `clock_out_success` | info | `{shift_id, duration_minutes, total_points}` |
| `clock_out_failure` | error | `{shift_id, error_message}` |
| `shift_closed_by_server` | warn | `{shift_id, reason, source: 'realtime'|'polling'}` |
| `midnight_warning` | info | `{shift_id}` |
| `midnight_closure` | info | `{shift_id}` |

### Sync Events (`event_category: 'sync'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `sync_started` | info | `{pending_shifts, pending_gps_points}` |
| `sync_completed` | info | `{synced_shifts, synced_points, failed, duration_ms}` |
| `sync_failed` | error | `{error_message, attempt_number}` |
| `batch_synced` | info | `{type: 'gps_points', inserted, duplicates, errors}` |
| `record_quarantined` | warn | `{type, record_id, reason, attempt_count}` |

### Auth Events (`event_category: 'auth'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `sign_in` | info | `{method: 'email'|'biometric'|'otp'}` |
| `sign_out` | info | `{reason: 'user'|'force_logout'|'session_expired'}` |
| `force_logout` | critical | `{source: 'realtime'|'polling'}` |
| `session_restored` | info | `{method: 'biometric'|'refresh_token'}` |

### Network Events (`event_category: 'network'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `connectivity_changed` | info | `{new_type: 'wifi'|'cellular'|'none', previous_type, offline_duration_seconds}` |
| `realtime_status_changed` | debug | `{channel, status, error}` |

### Permission Events (`event_category: 'permission'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `permission_changed` | warn | `{type: 'location', old_level, new_level}` |
| `permission_denied` | warn | `{type: 'location'|'notification', level}` |
| `battery_optimization_status` | info | `{is_exempt}` |

### Lifecycle Events (`event_category: 'lifecycle'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `app_started` | info | `{init_duration_ms, app_version, platform, os_version, device_model}` |
| `app_startup_failed` | critical | `{error_message, failed_service}` |
| `app_resumed` | debug | `{was_tracking, shift_active}` |
| `app_paused` | debug | `{is_tracking, shift_active}` |
| `db_recovery` | critical | `{reason: 'bad_decrypt', action: 'wipe_and_recreate'}` |
| `background_task_expired` | warn | `{task_name}` |

### Thermal Events (`event_category: 'thermal'`)

| Event | Severity | Metadata |
|-------|----------|----------|
| `thermal_level_changed` | info | `{old_level, new_level}` |
| `thermal_adaptation` | info | `{level, active_interval, stationary_interval}` |
| `thermal_read_error` | warn | `{error_message}` |
