# Work Session Flow Redesign

**Date:** 2026-03-11
**Status:** Approved

## Problem

The current work session flow has several UX friction points:

1. After completing a session, the employee must re-select the activity type even when starting the same type again.
2. Starting a new session requires tapping a FAB (floating action button) in the bottom-right corner — not discoverable.
3. Ménage (cleaning) has no distinction between short-term QR-based studios and long-term building/apartment cleaning.
4. Scanning a new QR code during an active session doesn't auto-close the current session.
5. Lunch break ("Pause dîner") is a separate button instead of appearing as an active session card like other sessions.

## Design

### 1. Default Activity Type Persistence

When an employee starts a new session after completing one, the **activity type** defaults to the last type used within the current shift.

- Only the activity type persists — not the location/building/studio.
- A "Changer d'activité" button appears at the bottom of the default choices, allowing the employee to switch types.
- On first session of a shift (no prior session), the full activity type picker is shown as today.

### 2. "Aucune session active" Zone Replaces FAB

The current "Aucune session active" card becomes tappable to start a new session, replacing the FAB.

- Tapping the card opens the session start flow (default activity type or type picker).
- The FAB is removed from the dashboard.
- Visual affordance: the card gets a subtle border or icon indicating it's tappable.

### 3. Ménage Split: Court Terme (QR) vs Long Terme (Immeuble)

When the employee selects Ménage, two sub-options appear:

#### Court terme — QR Scanner
- Opens the QR scanner directly.
- For short-term studio cleaning (existing flow).

#### Long terme — Immeuble/Appartement Picker
- Opens the same building picker used by Entretien.
- Employee can select either a whole building or a specific apartment.
- Creates a session with `activity_type = cleaning` but with building/apartment metadata instead of studio/QR data.

**UI flow:**
```
Ménage selected →
  ┌─────────────────────────────┐
  │  📷 Scanner un code QR      │  (court terme)
  │                             │
  │  🏢 Choisir un immeuble     │  (long terme)
  └─────────────────────────────┘
```

### 4. QR Scan During Active Session: Auto-Close + Open

If an employee scans a QR code while a session is already active:

1. The current session is automatically completed (closed).
2. A new session is immediately opened for the scanned QR code.
3. No confirmation dialog — this is the expected workflow for moving between studios.

### 5. New Session Flow with Defaults

When starting a new session and the employee's last activity type was, say, Ménage:

```
┌─────────────────────────────────┐
│  📷 Scanner un code QR          │  (default: ménage court terme)
│                                 │
│  🏢 Choisir un immeuble         │  (default: ménage long terme)
│                                 │
│  ─────────────────────────────  │
│  🔄 Changer d'activité          │  (opens full type picker)
└─────────────────────────────────┘
```

If the last type was Entretien:
```
┌─────────────────────────────────┐
│  🏢 Choisir un immeuble         │  (default: entretien)
│                                 │
│  ─────────────────────────────  │
│  🔄 Changer d'activité          │  (opens full type picker)
└─────────────────────────────────┘
```

If the last type was Administration:
```
┌─────────────────────────────────────────┐
│  Commencer une session Administration?  │
│                                         │
│  [Confirmer]                            │
│                                         │
│  ─────────────────────────────────────  │
│  🔄 Changer d'activité                  │
└─────────────────────────────────────────┘
```

### 6. Administration Confirmation Dialog

Administration sessions don't require a location. When selected (either as default or from the type picker):

- A confirmation dialog appears: "Commencer une session Administration?"
- "Confirmer" starts the session immediately.
- "Changer d'activité" navigates to the full type picker.

### 7. Lunch Break as Active Session Card

The lunch break ("Pause dîner") is displayed as an active session card at the bottom of the dashboard, identical in style to other work sessions — instead of the current separate `LunchBreakButton`.

- When lunch is active, it shows:
  - Orange/restaurant-themed color and icon (🍽️ `Icons.restaurant`)
  - "Pause dîner en cours" badge in the header
  - Live timer showing elapsed lunch duration
  - Start time ("Début: HH:MM")
  - "Fin pause" button to end the lunch break
- When no lunch is active, the lunch option integrates with the existing session flow — the `LunchBreakButton` remains as the trigger to start lunch (it already only shows during active shifts).
- The active lunch card replaces/hides the "Aucune session active" zone while lunch is ongoing.

**Key difference from work sessions:** Lunch breaks pause GPS tracking (via `pauseForLunch()`) and use the existing `lunch_breaks` table — they are NOT stored as `work_sessions`. The visual treatment is unified but the underlying data model stays separate.

## Components Affected

### Modified
- `ActivityType` enum — no changes needed (ménage sub-types are UI-level, not model-level)
- `ActiveWorkSessionCard` — make "Aucune session active" tappable; add lunch break active card display
- `ShiftDashboardScreen` — remove FAB, wire up tappable empty state, remove standalone `LunchBreakButton` during active lunch (show lunch as session card instead)
- `WorkSessionNotifier` / `WorkSessionProvider` — add `lastActivityType` persistence within shift
- `ActivityTypePicker` — add ménage sub-type selection (QR vs building picker)
- `QrScannerScreen` — auto-close active session on new scan

### New
- `SessionStartSheet` — bottom sheet for starting a new session with defaults + "Changer d'activité"

### Unchanged
- `LunchBreak` model, `LunchBreakProvider`, `lunch_breaks` table — data model stays the same
- `WorkSession` model — no schema changes
- Database / Supabase — no migrations needed

## Data Flow

```
Employee taps "Aucune session active"
  → Check lastActivityType for current shift
  → If exists: show SessionStartSheet with defaults
  → If null: show full ActivityTypePicker

SessionStartSheet
  → Ménage default: [QR Scanner] [Immeuble Picker] [Changer d'activité]
  → Entretien default: [Immeuble Picker] [Changer d'activité]
  → Admin default: [Confirmer] [Changer d'activité]

QR scan during active session
  → completeSession() on current
  → startSession() with scanned studio data

Lunch break start
  → LunchBreakProvider.startLunchBreak() (existing)
  → ActiveWorkSessionCard shows lunch active card (new visual)

Lunch break end
  → LunchBreakProvider.endLunchBreak() (existing)
  → Card returns to "Aucune session active" or active work session
```

## Error Handling

- **Auto-close on QR scan fails:** Show error snackbar, keep current session active, don't open new one.
- **No last activity type:** Fall back to full type picker (first session of shift).
- **Lunch + work session conflict:** Lunch break and work sessions are independent — an employee can have an active work session AND start lunch (which pauses GPS but doesn't close the work session). The lunch card takes visual priority when both are active.

## Testing

- Verify default activity type persists across sessions within a shift.
- Verify default resets on new shift (clock-out + clock-in).
- Verify ménage sub-type selection (QR vs building picker) creates correct session metadata.
- Verify QR scan during active session auto-closes + opens new session.
- Verify "Changer d'activité" navigates to full type picker.
- Verify administration confirmation dialog works.
- Verify lunch break shows as active session card with live timer.
- Verify lunch card disappears when lunch ends.
- Verify FAB is removed and "Aucune session active" is tappable.
