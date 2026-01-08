# Data Model: Project Foundation

**Feature Branch**: `001-project-foundation`
**Date**: 2026-01-08
**Derived From**: [spec.md](./spec.md) Key Entities

## Entity Relationship Diagram

```
┌─────────────────────┐
│  employee_profiles  │
├─────────────────────┤
│ id (PK, UUID)       │
│ email (unique)      │───────────────┐
│ full_name           │               │
│ employee_id         │               │
│ status              │               │
│ privacy_consent_at  │               │
│ created_at          │               │
│ updated_at          │               │
└─────────────────────┘               │
         │                            │
         │ 1:N                        │
         ▼                            │
┌─────────────────────┐               │
│       shifts        │               │
├─────────────────────┤               │
│ id (PK, UUID)       │               │
│ employee_id (FK)    │◄──────────────┘
│ request_id (unique) │  (idempotency key)
│ status              │
│ clocked_in_at       │
│ clock_in_location   │
│ clock_in_accuracy   │
│ clocked_out_at      │
│ clock_out_location  │
│ clock_out_accuracy  │
│ created_at          │
│ updated_at          │
└─────────────────────┘
         │
         │ 1:N
         ▼
┌─────────────────────┐
│     gps_points      │
├─────────────────────┤
│ id (PK, UUID)       │
│ client_id (unique)  │  (client-generated, idempotency)
│ shift_id (FK)       │
│ employee_id (FK)    │
│ latitude            │
│ longitude           │
│ accuracy            │
│ captured_at         │  (client timestamp)
│ received_at         │  (server timestamp)
│ device_id           │
│ sync_status         │
│ created_at          │
└─────────────────────┘
```

## Entities

### 1. employee_profiles

Represents a user of the application.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PK, DEFAULT gen_random_uuid() | Primary key, links to auth.users |
| `email` | TEXT | NOT NULL, UNIQUE | User email (from auth) |
| `full_name` | TEXT | NULL | Display name |
| `employee_id` | TEXT | NULL | Company employee ID |
| `status` | TEXT | NOT NULL, DEFAULT 'active' | Account status: 'active', 'inactive', 'suspended' |
| `privacy_consent_at` | TIMESTAMPTZ | NULL | When user accepted privacy policy |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update |

**Validation Rules**:
- `email` must be valid email format (enforced by auth)
- `status` must be one of: 'active', 'inactive', 'suspended'
- `privacy_consent_at` must be set before any location tracking can begin (Constitution III)

**Indexes**:
- `idx_employee_profiles_email` on `email`
- `idx_employee_profiles_status` on `status`

---

### 2. shifts

Represents a work session with clock in/out times.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PK, DEFAULT gen_random_uuid() | Primary key |
| `employee_id` | UUID | NOT NULL, FK → employee_profiles(id) | Owner of shift |
| `request_id` | UUID | UNIQUE | Idempotency key for clock operations |
| `status` | TEXT | NOT NULL, DEFAULT 'active' | Shift status: 'active', 'completed' |
| `clocked_in_at` | TIMESTAMPTZ | NOT NULL | Server timestamp of clock in |
| `clock_in_location` | JSONB | NULL | {latitude, longitude} at clock in |
| `clock_in_accuracy` | DECIMAL(8,2) | NULL | GPS accuracy in meters |
| `clocked_out_at` | TIMESTAMPTZ | NULL | Server timestamp of clock out |
| `clock_out_location` | JSONB | NULL | {latitude, longitude} at clock out |
| `clock_out_accuracy` | DECIMAL(8,2) | NULL | GPS accuracy in meters |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update |

**Validation Rules**:
- `status` must be one of: 'active', 'completed'
- Only one 'active' shift allowed per employee at any time
- `clocked_out_at` must be after `clocked_in_at` when set
- `clocked_out_at` required to transition status to 'completed'

**State Transitions**:
```
[No Shift] → clock_in → [Active Shift] → clock_out → [Completed Shift]
                              │
                              └── Cannot clock_in again while active
```

**Indexes**:
- `idx_shifts_employee_id` on `employee_id`
- `idx_shifts_status` on `status`
- `idx_shifts_employee_active` on `(employee_id, status)` WHERE status = 'active'

---

### 3. gps_points

Represents a location capture during an active shift.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PK, DEFAULT gen_random_uuid() | Server-generated primary key |
| `client_id` | UUID | NOT NULL, UNIQUE | Client-generated UUID for idempotency |
| `shift_id` | UUID | NOT NULL, FK → shifts(id) | Parent shift |
| `employee_id` | UUID | NOT NULL, FK → employee_profiles(id) | Owner (denormalized for RLS) |
| `latitude` | DECIMAL(10,8) | NOT NULL | GPS latitude (-90 to 90) |
| `longitude` | DECIMAL(11,8) | NOT NULL | GPS longitude (-180 to 180) |
| `accuracy` | DECIMAL(8,2) | NULL | GPS accuracy in meters |
| `captured_at` | TIMESTAMPTZ | NOT NULL | Client timestamp when captured |
| `received_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Server timestamp when synced |
| `device_id` | TEXT | NULL | Device identifier |
| `sync_status` | TEXT | NOT NULL, DEFAULT 'synced' | Always 'synced' in remote DB |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation |

**Validation Rules**:
- `latitude` must be between -90.0 and 90.0
- `longitude` must be between -180.0 and 180.0
- `captured_at` must be within shift's clocked_in_at and clocked_out_at (if set)
- `client_id` provides natural deduplication for offline sync

**Indexes**:
- `idx_gps_points_client_id` on `client_id` (UNIQUE)
- `idx_gps_points_shift_id` on `shift_id`
- `idx_gps_points_employee_id` on `employee_id`
- `idx_gps_points_captured_at` on `captured_at`

---

## Local Storage Schema (SQLite/SQLCipher)

For offline-first functionality, local tables mirror remote with sync metadata.

### local_gps_points

```sql
CREATE TABLE local_gps_points (
    client_id TEXT PRIMARY KEY,
    shift_id TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    accuracy REAL,
    captured_at INTEGER NOT NULL,        -- Unix timestamp ms
    sync_status TEXT DEFAULT 'pending',  -- pending, synced, failed
    sync_attempts INTEGER DEFAULT 0,
    last_sync_error TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);

CREATE INDEX idx_local_gps_pending ON local_gps_points(sync_status)
WHERE sync_status = 'pending';
```

### local_shifts

```sql
CREATE TABLE local_shifts (
    id TEXT PRIMARY KEY,
    request_id TEXT UNIQUE,
    employee_id TEXT NOT NULL,
    status TEXT DEFAULT 'active',
    clocked_in_at INTEGER,
    clock_in_latitude REAL,
    clock_in_longitude REAL,
    clock_in_accuracy REAL,
    clocked_out_at INTEGER,
    clock_out_latitude REAL,
    clock_out_longitude REAL,
    clock_out_accuracy REAL,
    sync_status TEXT DEFAULT 'pending',
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

### sync_metadata

```sql
CREATE TABLE sync_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);

-- Keys: last_sync_time, clock_offset_ms, device_id
```

---

## Row Level Security Policies

All tables require RLS with the optimized `(SELECT auth.uid())` pattern.

### employee_profiles

```sql
ALTER TABLE employee_profiles ENABLE ROW LEVEL SECURITY;

-- Users can only view their own profile
CREATE POLICY "Users can view own profile"
ON employee_profiles FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
ON employee_profiles FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = id)
WITH CHECK ((SELECT auth.uid()) = id);

-- Profile created via trigger on auth.users insert (not direct insert)
```

### shifts

```sql
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own shifts"
ON shifts FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can insert own shifts"
ON shifts FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can update own shifts"
ON shifts FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = employee_id)
WITH CHECK ((SELECT auth.uid()) = employee_id);
```

### gps_points

```sql
ALTER TABLE gps_points ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own GPS points"
ON gps_points FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can insert own GPS points"
ON gps_points FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- No UPDATE or DELETE - GPS points are immutable
```

---

## Migration Script Reference

See `supabase/migrations/001_initial_schema.sql` for the complete migration implementing this model.
