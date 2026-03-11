# Database Self-Documenting Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich all 36+ Supabase tables with structured COMMENT ON statements containing business logic, create a skill to enforce the practice, and update CLAUDE.md with a new mandatory rule.

**Architecture:** Three independent deliverables: (1) a Claude skill defining the comment format and consultation rules, (2) a CLAUDE.md rule update, (3) a single non-destructive SQL migration adding all COMMENT ON statements. The migration content is extracted from 19 specs, 74 plan docs, and 158 migration files.

**Tech Stack:** PostgreSQL COMMENT ON, Claude Code skills (SKILL.md format), Supabase MCP

---

## Chunk 1: Skill + CLAUDE.md (independent, can run in parallel)

### Task 1: Create skill `supabase-schema-context`

**Files:**
- Create: `/Users/cedric/.claude/skills/supabase-schema-context/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p /Users/cedric/.claude/skills/supabase-schema-context
```

- [ ] **Step 2: Write SKILL.md**

Create `/Users/cedric/.claude/skills/supabase-schema-context/SKILL.md` with this exact content:

```markdown
---
name: supabase-schema-context
description: Use BEFORE any task that involves the Supabase database — reading, querying, or modifying schema. Ensures Claude reads COMMENT ON metadata for context and updates comments when modifying tables.
---

# Supabase Schema Context

## When This Skill Applies

- Starting a task that involves database tables
- Writing a migration (CREATE TABLE, ALTER TABLE, DROP)
- Debugging a query or data issue
- Reviewing or understanding business logic tied to a table

## Before Starting Work

**Read the comments of every table you will touch:**

\```sql
-- Read table comment
SELECT obj_description(c.oid)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname = 'TABLE_NAME' AND n.nspname = 'public';

-- Read all column comments for a table
SELECT a.attname AS column_name, col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relname = 'TABLE_NAME' AND n.nspname = 'public'
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;
\```

**Do this ONCE per table per session.** No need to re-read on subsequent queries to the same table.

## When Writing Migrations

**Every migration that creates or modifies a table MUST include COMMENT ON statements.**

### Creating a new table
Add COMMENT ON TABLE and COMMENT ON COLUMN for all non-obvious columns in the same migration.

### Modifying a table
If adding/renaming/changing columns, update the relevant COMMENT ON statements in the same migration.

### Dropping a table
No action needed — comments are dropped automatically.

## Comment Format Standard

### Table comments (semi-structured)

\```sql
COMMENT ON TABLE table_name IS '
ROLE: One-sentence description of the table purpose.
STATUTS: value1 = meaning | value2 = meaning
REGLES: Business rule 1. Business rule 2.
RELATIONS: -> parent_table (N:1) | <- child_table (1:N)
TRIGGERS: On event -> effect.
ALGORITHME: Key calculation or detection logic summary.
RLS: Who can see/do what.
';
\```

### Available sections

| Section | When to use |
|---------|-------------|
| `ROLE:` | Always (mandatory) |
| `STATUTS:` | Table has a status/state column |
| `REGLES:` | Business constraints, limits, validations |
| `RELATIONS:` | Always (mandatory) — `->` parent, `<-` child |
| `TRIGGERS:` | Side effects, webhooks, notifications |
| `ALGORITHME:` | Complex calculations, detection logic |
| `RLS:` | Row-level security policies |

### Column comments

\```sql
COMMENT ON COLUMN table.column IS 'Description. Values: val1 = meaning | val2 = meaning';
\```

Only comment columns where the name alone is not sufficient to understand:
- Enum/status columns with specific values
- Calculated or derived columns
- Columns with non-obvious business meaning
- FK columns where the relationship is not obvious

Do NOT comment: `id`, `created_at`, `updated_at` (self-evident).

### Detail levels

| Level | For | Detail |
|-------|-----|--------|
| **C (maximal)** | Core business tables (~8) | All sections, full rules, algorithms |
| **B (standard)** | Most tables (~20) | ROLE + RELATIONS + relevant sections |
| **A (minimal)** | Utility/config tables (~5) | ROLE only, 1 line |

## Checklist

Before submitting any migration:
1. Did I read the existing comments of affected tables?
2. Does my migration include updated COMMENT ON for every table/column I changed?
3. For new tables: did I add COMMENT ON TABLE and COMMENT ON COLUMN for non-obvious columns?
4. Are my comments in the semi-structured format (ROLE/STATUTS/REGLES/RELATIONS)?
```

- [ ] **Step 3: Verify the skill is discoverable**

The skill should appear in Claude's available skills list. Test by starting a new conversation and checking if `supabase-schema-context` appears.

- [ ] **Step 4: Commit**

```bash
git add /Users/cedric/.claude/skills/supabase-schema-context/SKILL.md
git commit -m "feat: add supabase-schema-context skill for self-documenting DB"
```

---

### Task 2: Update CLAUDE.md with Rule 8

**Files:**
- Modify: `/Users/cedric/.claude/CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md**

Read `/Users/cedric/.claude/CLAUDE.md` to get current content.

- [ ] **Step 2: Add Rule 8 after Rule 7**

After the `## Terminal Tab Title System` section (which comes after Rule 7), add the following block BEFORE `## Terminal Tab Title System`:

```markdown
## Rule 8: Database Schema Context (MANDATORY)

When working on any task that involves the Supabase database:

### BEFORE starting work:
1. **Read COMMENT ON** for every table you will touch — use the queries from the `supabase-schema-context` skill. Do this ONCE per table per session.
2. **Understand the business logic** embedded in the comments before writing queries or migrations.

### WHEN writing migrations:
3. **Every migration** that creates or modifies a table MUST include updated `COMMENT ON TABLE` and `COMMENT ON COLUMN` statements in the semi-structured format (ROLE/STATUTS/REGLES/RELATIONS/TRIGGERS).
4. **New tables** require COMMENT ON TABLE + COMMENT ON COLUMN for all non-obvious columns.
5. **Modified tables** require updated comments for any changed columns.

### Format reference:
Use the `supabase-schema-context` skill for the full format standard and SQL queries.

### Why this rule exists:
The database comments ARE the business logic documentation. When Claude reads comments before working, it understands the domain without searching through 74 plan docs and 19 specs. When Claude updates comments in migrations, the documentation stays in sync with the schema automatically.
```

- [ ] **Step 3: Commit**

```bash
git add /Users/cedric/.claude/CLAUDE.md
git commit -m "feat: add Rule 8 — database schema context (MANDATORY)"
```

---

## Chunk 2: Extract business logic and generate migration

This chunk requires reading specs, plans, and migrations to extract business logic for each table. The work is parallelizable by domain.

### Task 3: Extract business logic — Core tables

**Sources to read:**
- `specs/002-employee-auth/spec.md` and `data-model.md`
- `specs/003-shift-management/spec.md` and `data-model.md`
- `specs/004-background-gps-tracking/spec.md` and `data-model.md`
- `specs/005-offline-resilience/spec.md`
- `docs/plans/2026-02-25-gps-clock-in-guard.md`
- `docs/plans/2026-02-25-shift-reconciliation.md`
- `docs/background-tracking-resilience-audit.md`
- Migrations: 001 (initial), 006 (employee history), 009 (roles), 019 (device info), 022 (device sessions), 025 (gps gaps)

**Tables to document:**
- `employee_profiles` (Level C)
- `shifts` (Level C)
- `gps_points` (Level C)
- `employee_supervisors` (Level B)
- `gps_gaps` (Level B)
- `employee_devices` / `active_device_sessions` (Level B)

- [ ] **Step 1: Read all source specs and plans listed above**

- [ ] **Step 2: Read the migration SQL files for these tables**

Search in `supabase/migrations/` for files that CREATE or ALTER these tables.

- [ ] **Step 3: Write COMMENT ON statements**

For each table, write COMMENT ON TABLE and COMMENT ON COLUMN statements following the semi-structured format. Extract:
- Role/purpose from specs
- Status values and transitions from data-model.md
- Business rules from spec.md
- Relationships from migration FK constraints
- RLS policies from migration files
- Algorithm details from plan docs

- [ ] **Step 4: Save output**

Write the SQL to: `docs/superpowers/scratch/comments-core-tables.sql`

---

### Task 4: Extract business logic — Trip & Mileage tables

**Sources to read:**
- `specs/017-mileage-tracking/spec.md` and `data-model.md`
- `docs/trip-detection-algorithm.md`
- `docs/plans/2026-02-27-cluster-first-trip-detection-plan.md`
- `docs/plans/2026-02-27-stationary-clusters-design.md`
- `docs/plans/2026-02-27-mileage-carpooling-vehicles-design.md`
- `docs/plans/2026-02-27-trip-stop-detection-design.md`
- `docs/plans/2026-02-27-gps-point-clustering-design.md`
- `docs/plans/2026-03-07-cluster-trip-continuity-design.md`
- `docs/plans/2026-03-07-same-location-gps-gap-merge-design.md`
- `docs/plans/2026-03-07-trip-anomaly-detection-design.md`
- `docs/plans/2026-03-02-speed-based-stationary-detection.md`
- Migrations: 032-035 (trips/mileage), 053 (ignored clusters), 056 (ignored endpoints), 060 (stationary clusters), 065 (vehicle periods), 066-067 (carpools)

**Tables to document:**
- `trips` (Level C)
- `stationary_clusters` (Level C)
- `trip_gps_points` (Level B)
- `reimbursement_rates` (Level B)
- `mileage_reports` (Level B)
- `employee_vehicle_periods` (Level B)
- `carpool_groups` (Level B)
- `carpool_members` (Level B)
- `ignored_location_clusters` (Level B)
- `ignored_trip_endpoints` (Level B)

- [ ] **Step 1: Read all source specs, plans, and algorithm docs listed above**

- [ ] **Step 2: Read the migration SQL files for these tables**

- [ ] **Step 3: Write COMMENT ON statements**

Pay special attention to:
- Trip detection algorithm parameters (speed thresholds, gap limits, min distances)
- Cluster detection algorithm (DBSCAN-like, EPS, spatial coherence)
- Carpool detection logic (union-find, vehicle periods)
- Reimbursement rate tiers (CRA rates, thresholds)
- Classification rules (business vs personal, driving vs walking)

- [ ] **Step 4: Save output**

Write the SQL to: `docs/superpowers/scratch/comments-trip-mileage-tables.sql`

---

### Task 5: Extract business logic — Cleaning & Property tables

**Sources to read:**
- `specs/016-cleaning-qr-tracking/spec.md` and `data-model.md`
- Migrations: 016 (cleaning), 017 (property), 018 (maintenance)

**Tables to document:**
- `cleaning_sessions` (Level C)
- `buildings` (Level B)
- `studios` (Level B)
- `property_buildings` (Level B)
- `apartments` (Level B)
- `maintenance_sessions` (Level B)

- [ ] **Step 1: Read all source specs listed above**

- [ ] **Step 2: Read the migration SQL files for these tables**

- [ ] **Step 3: Write COMMENT ON statements**

Pay special attention to:
- Cleaning session lifecycle (QR scan start, auto-close, manual close)
- Studio types (unit, common_area, conciergerie)
- Flagging logic (is_flagged, flag_reason)
- Relationship between buildings/studios and property_buildings/apartments

- [ ] **Step 4: Save output**

Write the SQL to: `docs/superpowers/scratch/comments-cleaning-property-tables.sql`

---

### Task 6: Extract business logic — Location & Approval tables

**Sources to read:**
- `specs/015-location-geofences/spec.md` and `data-model.md`
- `docs/plans/2026-02-28-hours-approval-design.md`
- `docs/plans/2026-02-28-hours-approval-plan.md`
- `docs/plans/2026-03-06-approval-simplification-design.md`
- `docs/plans/2026-03-06-approval-simplification-plan.md`
- `docs/plans/2026-03-09-approval-stability-cascade-design.md`
- `docs/plans/2026-02-26-trip-location-matching-design.md`
- `docs/plans/2026-02-28-home-override-building-linking-design.md`
- `docs/plans/2026-03-05-location-overlap-prevention.md`
- `docs/plans/2026-03-02-gps-gap-visibility-approvals-design.md`
- Migrations: 015 (locations), 093 (approvals), 099 (home override)

**Tables to document:**
- `locations` (Level C)
- `day_approvals` (Level C)
- `location_matches` (Level B)
- `activity_overrides` (Level B)
- `employee_home_locations` (Level B)

- [ ] **Step 1: Read all source specs and plans listed above**

- [ ] **Step 2: Read the migration SQL files for these tables**

- [ ] **Step 3: Write COMMENT ON statements**

Pay special attention to:
- Location types and geofence radius logic
- PostGIS geography column usage
- Approval workflow (pending -> approved, cascade rules)
- Activity override types and their effect on hours calculation
- Home location override logic

- [ ] **Step 4: Save output**

Write the SQL to: `docs/superpowers/scratch/comments-location-approval-tables.sql`

---

### Task 7: Extract business logic — Dashboard, Reports & Utility tables

**Sources to read:**
- `specs/009-dashboard-foundation/spec.md`
- `specs/010-employee-management/spec.md`
- `specs/011-shift-monitoring/spec.md`
- `specs/013-reports-export/spec.md`
- `specs/019-diagnostic-logging/spec.md`
- `docs/plans/2026-03-06-lunch-break-design.md`
- Migrations: 010 (aggregations), 012 (shift monitoring), 014 (reports), 020 (app_config), 038 (diagnostic), 064 (device status), 129 (lunch breaks), 139 (app_settings)
- Audit schema: migration 011

**Tables to document:**
- `diagnostic_logs` (Level B)
- `device_status` (Level B)
- `lunch_breaks` (Level B)
- `report_schedules` (Level B)
- `report_jobs` (Level A)
- `report_audit_logs` (Level A)
- `app_config` (Level A)
- `app_settings` (Level A)
- `audit.audit_logs` (Level B)

- [ ] **Step 1: Read all source specs and plans listed above**

- [ ] **Step 2: Read the migration SQL files for these tables**

- [ ] **Step 3: Write COMMENT ON statements**

- [ ] **Step 4: Save output**

Write the SQL to: `docs/superpowers/scratch/comments-dashboard-utility-tables.sql`

---

## Chunk 3: Assemble and apply migration

### Task 8: Assemble the complete migration

**Files:**
- Read: `docs/superpowers/scratch/comments-*.sql` (all 5 files from Tasks 3-7)
- Create: `supabase/migrations/YYYYMMDDHHMMSS_add_schema_comments.sql`

- [ ] **Step 1: Read all 5 scratch SQL files**

Read all files from `docs/superpowers/scratch/`:
- `comments-core-tables.sql`
- `comments-trip-mileage-tables.sql`
- `comments-cleaning-property-tables.sql`
- `comments-location-approval-tables.sql`
- `comments-dashboard-utility-tables.sql`

- [ ] **Step 2: Assemble into a single migration file**

Combine all COMMENT ON statements into one migration file. Organize by table grouping with SQL comments as section headers:

```sql
-- ============================================================
-- Migration: Add comprehensive COMMENT ON to all tables
-- Purpose: Self-documenting database for AI-assisted development
-- Non-destructive: Only adds metadata, no schema/data changes
-- ============================================================

-- ============================================================
-- CORE TABLES
-- ============================================================

-- employee_profiles
COMMENT ON TABLE employee_profiles IS '...';
COMMENT ON COLUMN employee_profiles.role IS '...';
-- ... etc

-- ============================================================
-- TRIP & MILEAGE TABLES
-- ============================================================

-- ... etc
```

- [ ] **Step 3: Validate SQL syntax**

Run the migration through a syntax check:
```bash
psql -h localhost -p 54322 -U postgres -d postgres -f migration_file.sql --dry-run 2>&1 | head -20
```

Or use the Supabase MCP to validate.

- [ ] **Step 4: Present to user for review**

Show the complete migration to the user. This is non-destructive (COMMENT ON only) but the user should validate the business logic content is accurate.

- [ ] **Step 5: Apply the migration**

Use Supabase MCP `apply_migration` to apply.

- [ ] **Step 6: Verify comments are accessible**

```sql
-- Spot-check: read comments for a core table
SELECT obj_description(c.oid) FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname = 'shifts' AND n.nspname = 'public';
```

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/*_add_schema_comments.sql
git commit -m "feat: add COMMENT ON to all 36+ tables — self-documenting DB"
```

- [ ] **Step 8: Clean up scratch files**

```bash
rm -rf docs/superpowers/scratch/
```

---

## Parallelization Map

```
Task 1 (skill)  ─────────────────────────────┐
Task 2 (CLAUDE.md) ──────────────────────────┤
Task 3 (core tables) ───────────────────────┤
Task 4 (trip/mileage tables) ───────────────┼──→ Task 8 (assemble) ──→ Done
Task 5 (cleaning/property tables) ──────────┤
Task 6 (location/approval tables) ──────────┤
Task 7 (dashboard/utility tables) ──────────┘
```

Tasks 1-7 are fully independent and can run in parallel.
Task 8 depends on all of Tasks 3-7 completing.

## Notes for Agents

- **All paths are absolute.** The project root is `/Users/cedric/Desktop/Desktop - Cedric's MacBook Pro - 1/PROJECT/TEST/GPS_Tracker/`
- **Do NOT modify any existing table structure.** This is COMMENT ON only — pure metadata.
- **Use the Supabase MCP** for SQL queries (`execute_sql`). For reading spec files, use the `Read` tool.
- **When reading migrations**, search for files containing the table name in `supabase/migrations/`. Migration files are named `YYYYMMDDHHMMSS_description.sql`.
- **Semi-structured format is mandatory.** Every table comment must use `ROLE:` and `RELATIONS:` at minimum. Other sections as applicable.
- **Column comments** only for non-obvious columns. Skip `id`, `created_at`, `updated_at`.
- **Write in clear French** for business-facing descriptions (the team is francophone). Technical terms (FK, PostGIS, DBSCAN, etc.) stay in English.
