# Hours Approval System — Design Document

**Date**: 2026-02-28
**Feature**: Shift hours approval workflow with automatic classification
**Scope**: Dashboard (Next.js) + Supabase (migrations, RPCs)

---

## Problem

Administrators need to review and approve employee work hours daily. Currently, shifts are either "active" or "completed" with no approval workflow. There is no way to:
- Automatically flag non-work time (commute from home, personal stops)
- Track which days have been reviewed and approved
- Navigate efficiently across employees and days to manage approvals

## Solution Overview

A two-level approval system:
1. **Line-level auto-classification**: Each activity line (trip, stop, clock event) gets an automatic status based on location matching rules
2. **Day-level approval**: The administrator reviews the auto-classified lines, resolves ambiguous items, and approves the full day

### Architecture: On-the-fly calculation (Approach A)
- Auto-classification is computed dynamically when the admin opens the view
- Only admin decisions (overrides) and final approvals are stored in the database
- Once a day is approved, the approved hours are frozen in the DB
- If locations change after approval, approved days are NOT affected
- Pending days automatically reflect updated location data

---

## Auto-Classification Rules

### Stop Rules

| Location Type | Auto Status | Reason |
|---------------|-------------|--------|
| `office` | approved | Lieu de travail |
| `building` | approved | Lieu de travail |
| `vendor` | approved | Fournisseur |
| `home` | rejected | Domicile |
| `other` | rejected | Lieu non-professionnel (cafe, restaurant, etc.) |
| No match | needs_review | Lieu inconnu |

### Trip Rules

| Condition | Auto Status | Reason |
|-----------|-------------|--------|
| Departure approved AND arrival approved | approved | Deplacement professionnel |
| Touches a rejected stop (home/other) | rejected | Trajet personnel |
| Touches an unknown stop | needs_review | Destination inconnue |
| Duration > 60 minutes | needs_review | Trajet anormalement long |
| Has GPS gap (`has_gps_gap = true`) | needs_review | Donnees GPS incompletes |

### Clock Event Rules

| Condition | Auto Status | Reason |
|-----------|-------------|--------|
| Matched to office/building/vendor | approved | Lieu de travail |
| Matched to home/other | rejected | Hors lieu de travail |
| No location match | needs_review | Lieu inconnu |

### Key Behavior: Home commute and mid-shift personal stops

- **Morning commute**: Clock-in at home + travel to first work location → both rejected
- **Evening commute**: Travel from last work location to home + clock-out at home → both rejected
- **Mid-shift personal stop**: Travel to home/other, stop at home/other, travel back → all three rejected
- **Inter-work travel**: Travel between two approved locations (office→vendor, building→office) → approved

### Approved Hours Calculation

```
approved_minutes = SUM(duration) WHERE final_status = 'approved'
rejected_minutes = SUM(duration) WHERE final_status = 'rejected'
final_status = COALESCE(override_status, auto_status)
```

---

## Database Schema

### Migration ~092: `hours_approval`

#### Table: `day_approvals`

```sql
CREATE TABLE day_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  total_shift_minutes INT,           -- raw shift duration (clock-in to clock-out)
  approved_minutes INT,              -- frozen on approval
  rejected_minutes INT,              -- frozen on approval
  approved_by UUID REFERENCES employee_profiles(id),
  approved_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, date)
);
```

#### Table: `activity_overrides`

```sql
CREATE TABLE activity_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  day_approval_id UUID NOT NULL REFERENCES day_approvals(id) ON DELETE CASCADE,
  activity_type TEXT NOT NULL CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out')),
  activity_id UUID NOT NULL,         -- FK to trips.id, stationary_clusters.id, or shifts.id
  override_status TEXT NOT NULL CHECK (override_status IN ('approved', 'rejected')),
  reason TEXT,                       -- optional admin note
  created_by UUID NOT NULL REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(day_approval_id, activity_type, activity_id)
);
```

#### RLS Policies
- `day_approvals`: admin/super_admin full access, employees can SELECT own rows
- `activity_overrides`: admin/super_admin full access via join to day_approvals

---

## RPCs

### RPC 1: `get_weekly_approval_summary(p_week_start DATE)`

Returns the weekly grid data for all employees visible to the caller.

**Input**: `p_week_start` (Monday of the week)

**Output**: Array of employee rows, each with 7 day entries:
```json
[
  {
    "employee_id": "uuid",
    "employee_name": "Jean Dupont",
    "days": [
      {
        "date": "2026-02-24",
        "has_shifts": true,
        "status": "approved | pending | needs_review",
        "total_shift_minutes": 510,
        "approved_minutes": 480,
        "rejected_minutes": 30,
        "needs_review_count": 0
      }
    ]
  }
]
```

**Logic**:
1. Get all employees (filtered by supervisor RLS)
2. For each day of the week (Mon-Sun):
   - Find completed shifts for that employee on that date
   - If `day_approvals` exists with `status='approved'` → return frozen values
   - Else → call internal classification logic to compute auto statuses + apply existing overrides

### RPC 2: `get_day_approval_detail(p_employee_id UUID, p_date DATE)`

Returns the full activity timeline for one employee's day, annotated with approval statuses.

**Output**:
```json
{
  "employee_id": "uuid",
  "date": "2026-02-27",
  "approval_status": "pending | approved",
  "activities": [
    {
      "activity_type": "stop | trip | clock_in | clock_out",
      "activity_id": "uuid",
      "started_at": "timestamptz",
      "ended_at": "timestamptz",
      "duration_minutes": 270,
      "auto_status": "approved | rejected | needs_review",
      "auto_reason": "Lieu de travail",
      "override_status": null,
      "final_status": "approved",
      "location_name": "Bureau principal",
      "location_type": "office",
      "details": {}
    }
  ],
  "summary": {
    "total_shift_minutes": 510,
    "approved_minutes": 480,
    "rejected_minutes": 30,
    "needs_review_count": 0
  }
}
```

**Logic**: Reuses `get_employee_activity()` output, applies classification rules, merges with existing overrides from `activity_overrides`.

### RPC 3: `save_activity_override(p_employee_id UUID, p_date DATE, p_activity_type TEXT, p_activity_id UUID, p_status TEXT, p_reason TEXT)`

Saves an admin override on a single activity line.

**Logic**:
1. Find or create `day_approvals` row for (employee_id, date) with status='pending'
2. Upsert into `activity_overrides`
3. Return updated summary (approved/rejected/needs_review counts)

### RPC 4: `approve_day(p_employee_id UUID, p_date DATE, p_notes TEXT)`

Freezes the day approval.

**Logic**:
1. Compute final status for all activities (auto + overrides)
2. Verify no `needs_review` items remain (error if any)
3. Calculate total approved_minutes and rejected_minutes
4. Update `day_approvals` set status='approved', approved_by, approved_at, frozen totals
5. Return the approved record

---

## Dashboard UI

### New Page: `/dashboard/approvals`

#### Weekly Grid View (Main)

- **Layout**: Table with rows = employees, columns = days of the week (Mon-Sun)
- **Navigation**: Week selector with arrows (previous/next week)
- **Cell content**: Approved hours + status badge
  - Green (approved): Day fully approved by admin
  - Yellow (pending): Has shifts but not yet approved (may have needs_review items)
  - Red (needs_review): Has needs_review items requiring attention
  - Grey/dash: No shifts on that day
- **Filters**:
  - Status filter: All / Not approved / Approved
  - Employee search
- **Summary row**: Total approved hours per employee for the week

#### Day Detail Panel (Click on cell)

- Opens as a side panel or modal
- Shows employee name, date, shift times, total hours
- Activity timeline with approval status indicators per line:
  - Green check: approved (auto or override)
  - Red X: rejected (auto or override)
  - Yellow warning: needs review
- Each line is clickable to toggle approval/rejection
- Override reason input (optional)
- Summary bar: approved/rejected/needs_review counts + hours
- "Approve Day" button: enabled only when needs_review_count = 0

### Sidebar Integration

Add "Approbation" entry to the dashboard sidebar, between "Activites" and "Rapports".

---

## Edge Cases

1. **Active shift (still clocked in)**: Cannot approve — day shows as "in progress" (grey), not clickable
2. **Midnight-closed shift**: Treated as a normal completed shift for the day it started
3. **Multiple shifts in one day**: All combined into a single day view, all must be reviewed
4. **Shift spanning midnight**: Belongs to the day it started (based on clocked_in_at)
5. **Employee with no shifts**: Not shown in the grid (or shown with all grey cells)
6. **Re-running detect_trips**: If trips are re-detected after overrides exist, orphaned overrides (referencing deleted trip IDs) are ignored gracefully
7. **Location added after override**: Override takes precedence over new auto-classification
8. **Approved day, then location changes**: Approved day remains frozen — no recalculation

---

## Non-Goals (Deferred)

- Employee self-submission of hours (employees don't interact with approval)
- Overtime calculation or pay period integration
- Email/push notifications when day is approved or flagged
- Bulk approval (approve all days for an employee at once)
- Export of approved hours to payroll systems
