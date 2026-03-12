# Work Session Flow Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the work session UX — default activity type, tappable empty state, ménage split, QR auto-close, lunch as session card.

**Architecture:** Modify existing work session widgets and providers; add a new `SessionStartSheet` bottom sheet. No DB migrations — uses existing `local_work_sessions` table and `lunch_breaks` table. The `_resolveLocationType` in `WorkSessionService` gains a new `'building'` branch for cleaning long terme.

**Tech Stack:** Flutter/Dart, flutter_riverpod, sqflite_sqlcipher, mobile_scanner

**Spec:** `docs/superpowers/specs/2026-03-11-work-session-flow-redesign-design.md`

---

## Chunk 1: Data Layer + Provider Changes

### Task 1: Add `lastActivityType` query to `WorkSessionLocalDb`

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart`

- [ ] **Step 1: Add `getLastActivityTypeForShift` method**

Add this method after `getInProgressSessionsForShift` (around line 426):

```dart
/// Get the activity type of the most recently completed session for a shift.
/// Returns null if no completed sessions exist for this shift.
Future<String?> getLastActivityTypeForShift(String shiftId) async {
  await ensureTables();
  try {
    final results = await _localDb.transaction((txn) async {
      return await txn.rawQuery('''
        SELECT activity_type
        FROM local_work_sessions
        WHERE shift_id = ? AND status != 'in_progress'
        ORDER BY completed_at DESC
        LIMIT 1
      ''', [shiftId]);
    });
    if (results.isEmpty) return null;
    return results.first['activity_type'] as String?;
  } catch (e) {
    return null;
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/services/work_session_local_db.dart`
Expected: No issues

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart
git commit -m "feat: add lastActivityType query to WorkSessionLocalDb"
```

---

### Task 2: Add `lastActivityTypeProvider` to `work_session_provider.dart`

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart`

- [ ] **Step 1: Add the provider**

Add after `shiftWorkSessionsProvider` (around line 438):

```dart
/// Provider for the last activity type used in the current shift.
/// Returns null if no sessions have been completed yet in this shift.
final lastActivityTypeProvider = FutureProvider<ActivityType?>((ref) async {
  final shiftState = ref.watch(shiftProvider);
  ref.watch(workSessionProvider); // Invalidate when session state changes
  final shift = shiftState.activeShift;
  if (shift == null) return null;

  final localDb = ref.watch(workSessionLocalDbProvider);
  final typeStr = await localDb.getLastActivityTypeForShift(shift.id);
  if (typeStr == null) return null;
  return ActivityType.fromJson(typeStr);
});
```

- [ ] **Step 2: Ensure the provider invalidates when a session completes**

The provider already watches `shiftProvider`, and `workSessionProvider` changes trigger rebuilds downstream. The `lastActivityTypeProvider` is a `FutureProvider` that re-queries the DB each time it's watched, so it will pick up new completed sessions automatically when the widget tree rebuilds.

- [ ] **Step 3: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/providers/work_session_provider.dart`
Expected: No issues

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart
git commit -m "feat: add lastActivityTypeProvider for default session type"
```

---

### Task 3: Update `_resolveLocationType` for cleaning long terme

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/services/work_session_service.dart:672-685`

- [ ] **Step 1: Update the method**

Change `_resolveLocationType` to accept `studioId` and `buildingId` parameters:

```dart
/// Resolve the location_type based on activity type and available IDs.
String? _resolveLocationType(
  ActivityType activityType, {
  String? studioId,
  String? buildingId,
  String? apartmentId,
}) {
  switch (activityType) {
    case ActivityType.cleaning:
      // Court terme (QR studio) vs long terme (building/apartment)
      if (studioId != null) return 'studio';
      if (buildingId != null) return apartmentId != null ? 'apartment' : 'building';
      return 'studio'; // fallback
    case ActivityType.maintenance:
      return apartmentId != null ? 'apartment' : 'building';
    case ActivityType.admin:
      return null;
  }
}
```

- [ ] **Step 2: Update all call sites of `_resolveLocationType`**

Find all places that call `_resolveLocationType` and pass the new params. The method is called in the `startSession` method — update the call to pass `studioId` and `buildingId`:

```dart
locationType: _resolveLocationType(
  activityType,
  studioId: studioId,
  buildingId: buildingId,
  apartmentId: apartmentId,
),
```

- [ ] **Step 3: Update `locationLabel` in `WorkSession` model**

In `gps_tracker/lib/features/work_sessions/models/work_session.dart`, update the `locationLabel` getter to handle cleaning sessions with building data:

```dart
String get locationLabel {
  switch (activityType) {
    case ActivityType.cleaning:
      // Long terme: building-based cleaning
      if (studioNumber == null && studioId == null && buildingName != null) {
        if (unitNumber != null) return '$unitNumber — $buildingName';
        return buildingName!;
      }
      // Court terme: studio-based cleaning
      if (studioNumber != null && buildingName != null) {
        return '$studioNumber — $buildingName';
      }
      return studioNumber ?? studioId ?? '';
    case ActivityType.maintenance:
      if (unitNumber != null && buildingName != null) {
        return '$unitNumber — $buildingName';
      }
      return buildingName ?? '';
    case ActivityType.admin:
      return 'Administration';
  }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/`
Expected: No issues

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_service.dart
git add gps_tracker/lib/features/work_sessions/models/work_session.dart
git commit -m "feat: support 'building' locationType for cleaning long terme"
```

---

## Chunk 2: SessionStartSheet + Tappable Empty State

### Task 4: Create `SessionStartSheet` bottom sheet widget

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/widgets/session_start_sheet.dart`

- [ ] **Step 1: Create the widget**

```dart
import 'package:flutter/material.dart';

import '../models/activity_type.dart';

/// Result returned by SessionStartSheet.
class SessionStartResult {
  final SessionStartAction action;
  final ActivityType? activityType;

  const SessionStartResult(this.action, [this.activityType]);
}

enum SessionStartAction {
  /// Open QR scanner (ménage court terme)
  qrScan,
  /// Open building picker (ménage long terme or entretien)
  buildingPicker,
  /// Start admin session directly
  confirmAdmin,
  /// User wants to change activity type — show full picker
  changeType,
}

/// Modal bottom sheet shown when tapping "Aucune session active".
///
/// If lastActivityType exists, shows default options for that type.
/// Otherwise returns [SessionStartAction.changeType] to trigger full picker.
class SessionStartSheet extends StatelessWidget {
  final ActivityType defaultType;

  const SessionStartSheet({super.key, required this.defaultType});

  /// Show the sheet. Returns null if dismissed.
  static Future<SessionStartResult?> show(
    BuildContext context,
    ActivityType defaultType,
  ) {
    return showModalBottomSheet<SessionStartResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SessionStartSheet(defaultType: defaultType),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final color = defaultType.color;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: bottomPadding + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(defaultType.icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nouvelle session — ${defaultType.displayName}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Options based on activity type
            ..._buildOptions(context, color),

            // Divider
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),

            // Change activity type
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  const SessionStartResult(SessionStartAction.changeType),
                ),
                icon: const Icon(Icons.swap_horiz, size: 20),
                label: const Text("Changer d'activité"),
                style: TextButton.styleFrom(foregroundColor: Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOptions(BuildContext context, Color color) {
    switch (defaultType) {
      case ActivityType.cleaning:
        return [
          _OptionTile(
            icon: Icons.qr_code_scanner,
            label: 'Scanner un code QR',
            subtitle: 'Court terme — studios',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.qrScan),
            ),
          ),
          const SizedBox(height: 10),
          _OptionTile(
            icon: Icons.apartment,
            label: 'Choisir un immeuble',
            subtitle: 'Long terme — immeubles / appartements',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.buildingPicker),
            ),
          ),
        ];
      case ActivityType.maintenance:
        return [
          _OptionTile(
            icon: Icons.apartment,
            label: 'Choisir un immeuble',
            subtitle: 'Bâtiment ou appartement',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.buildingPicker),
            ),
          ),
        ];
      case ActivityType.admin:
        return [
          _OptionTile(
            icon: Icons.business_center,
            label: 'Commencer une session Administration',
            subtitle: 'Aucun lieu requis',
            color: color,
            onTap: () => Navigator.pop(
              context,
              const SessionStartResult(SessionStartAction.confirmAdmin),
            ),
          ),
        ];
    }
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/widgets/session_start_sheet.dart`
Expected: No issues

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/session_start_sheet.dart
git commit -m "feat: create SessionStartSheet for default activity type flow"
```

---

### Task 5: Make "Aucune session active" tappable in `ActiveWorkSessionCard`

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart:186-216`

- [ ] **Step 1: Add onStartSession callback**

Add a callback parameter to `ActiveWorkSessionCard`:

```dart
class ActiveWorkSessionCard extends ConsumerStatefulWidget {
  final VoidCallback? onStartSession;
  const ActiveWorkSessionCard({super.key, this.onStartSession});
```

- [ ] **Step 2: Make empty state tappable**

Replace `_buildEmptyState` method (lines 186-216) with:

```dart
Widget _buildEmptyState(ThemeData theme) {
  return Card(
    elevation: 1,
    child: InkWell(
      onTap: widget.onStartSession,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 40,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              'Aucune session active',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Appuyez pour démarrer une activité',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/widgets/active_work_session_card.dart`
Expected: No issues

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart
git commit -m "feat: make 'Aucune session active' card tappable"
```

---

### Task 6: Add lunch break active card to `ActiveWorkSessionCard`

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart`

- [ ] **Step 1: Add lunch break imports and watch**

Add imports at top:

```dart
import '../../shifts/providers/lunch_break_provider.dart';
import '../../shifts/providers/shift_provider.dart';
```

- [ ] **Step 2: Update build method to show lunch card + work session card together**

Replace the `build` method (line 175) to support both cards coexisting:

```dart
@override
Widget build(BuildContext context) {
  final session = ref.watch(activeWorkSessionProvider);
  final lunchState = ref.watch(lunchBreakProvider);
  final theme = Theme.of(context);

  // Both lunch and work session can be active simultaneously
  final showLunch = lunchState.isOnLunch;
  final showSession = session != null;

  if (!showLunch && !showSession) {
    return _buildEmptyState(theme);
  }

  return Column(
    children: [
      if (showLunch) _buildLunchCard(theme, lunchState),
      if (showLunch && showSession) const SizedBox(height: 12),
      if (showSession) _buildActiveSession(theme, session!),
    ],
  );
}
```

- [ ] **Step 3: Update `_recalculateElapsed` to also handle lunch timer**

The existing `_timer` already calls `_recalculateElapsed` every second. Update it to also trigger rebuilds when lunch is active (the periodic `setState` in `_recalculateElapsed` already forces a rebuild, and `_buildLunchCard` computes elapsed from `DateTime.now()` on each build — so no extra state is needed; the timer already drives the refresh).

Update `_recalculateElapsed`:

```dart
void _recalculateElapsed() {
  final session = ref.read(activeWorkSessionProvider);
  final lunchState = ref.read(lunchBreakProvider);

  if (session != null && session.status.isActive) {
    setState(() {
      _elapsed = DateTime.now().difference(session.startedAt);
    });
  } else if (lunchState.isOnLunch) {
    // Force rebuild so lunch timer updates
    setState(() {});
  }
}
```

- [ ] **Step 4: Add `_buildLunchCard` method**

Add after `_buildEmptyState`:

```dart
Widget _buildLunchCard(ThemeData theme, LunchBreakState lunchState) {
  final lunchBreak = lunchState.activeLunchBreak!;
  final elapsed = DateTime.now().difference(lunchBreak.startedAt);
  final color = Colors.orange.shade600;

  final formatTime = (DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  };

  return Card(
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: color.withValues(alpha: 0.4), width: 2),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 12, height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 8, spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.restaurant, size: 16, color: color),
                    const SizedBox(width: 4),
                    Text(
                      'Pause dîner en cours',
                      style: TextStyle(
                        fontSize: 13, color: color, fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Location info
          Row(
            children: [
              Icon(Icons.restaurant, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pause dîner',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Timer
          Center(
            child: Text(
              _formatDuration(elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontFeatures: [const FontFeature.tabularFigures()],
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Start time
          Center(
            child: Text(
              'Début: ${formatTime(lunchBreak.startedAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // End button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: lunchState.isEnding
                  ? null
                  : () => ref.read(lunchBreakProvider.notifier).endLunchBreak(),
              icon: lunchState.isEnding
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_circle),
              label: Text(lunchState.isEnding ? 'Fin en cours...' : 'Fin pause'),
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
            ),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/widgets/active_work_session_card.dart`
Expected: No issues

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart
git commit -m "feat: display lunch break as active session card with live timer"
```

---

### Task 7: Update `ActiveWorkSessionCard` cleaning location display

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart:373-413`

- [ ] **Step 1: Update `_buildCleaningLocation` to handle building-based cleaning**

Replace the method:

```dart
Widget _buildCleaningLocation(
  ThemeData theme,
  WorkSession session,
  Color activityColor,
) {
  // Long terme: building-based cleaning (no studio)
  if (session.studioId == null && session.studioNumber == null && session.buildingName != null) {
    return Row(
      children: [
        Icon(Icons.apartment, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.buildingName!,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (session.unitNumber != null)
                Text(
                  session.unitNumber!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        _LocationBadge(
          label: session.unitNumber != null ? 'Appart.' : 'Immeuble',
          color: activityColor,
        ),
      ],
    );
  }

  // Court terme: studio-based cleaning (existing)
  return Row(
    children: [
      Icon(Icons.meeting_room, size: 20, color: theme.colorScheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.studioNumber ?? session.studioId ?? '',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (session.buildingName != null)
              Text(
                session.buildingName!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      if (session.studioType != null)
        _LocationBadge(label: session.studioType!, color: activityColor),
    ],
  );
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/widgets/active_work_session_card.dart`
Expected: No issues

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart
git commit -m "feat: handle building-based cleaning display in ActiveWorkSessionCard"
```

---

## Chunk 3: Dashboard Integration

### Task 8: Wire up `SessionStartSheet` and remove FAB in `ShiftDashboardScreen`

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

- [ ] **Step 1: Add import for SessionStartSheet**

Add at top with other work session imports:

```dart
import '../../work_sessions/widgets/session_start_sheet.dart';
```

- [ ] **Step 2: Replace `_startNewSession` method**

Replace the existing `_startNewSession` (lines 1340-1399) with:

```dart
/// Start a new work session.
///
/// If a previous session exists for this shift, show SessionStartSheet
/// with default activity type. Otherwise show full ActivityTypePicker.
Future<void> _startNewSession() async {
  final activeShift = ref.read(shiftProvider).activeShift;
  if (activeShift == null) return;

  // Check for last activity type
  final lastTypeAsync = ref.read(lastActivityTypeProvider);
  final lastType = lastTypeAsync.valueOrNull;

  if (lastType != null) {
    // Show SessionStartSheet with defaults
    final result = await SessionStartSheet.show(context, lastType);
    if (result == null || !mounted) return;

    switch (result.action) {
      case SessionStartAction.qrScan:
        _openQrScanner();
      case SessionStartAction.buildingPicker:
        // Determine activity type: if default is cleaning, use cleaning; else maintenance
        await _openBuildingPickerForType(lastType);
      case SessionStartAction.confirmAdmin:
        await _startAdminSession(activeShift);
      case SessionStartAction.changeType:
        await _startNewSessionFullPicker();
    }
  } else {
    // First session of shift — full picker
    await _startNewSessionFullPicker();
  }
}

/// Full activity type picker flow (used for first session or "Changer d'activité").
Future<void> _startNewSessionFullPicker() async {
  final activityType = await ActivityTypePicker.show(context);
  if (activityType == null || !mounted) return;

  final activeShift = ref.read(shiftProvider).activeShift;
  if (activeShift == null) return;

  switch (activityType) {
    case ActivityType.cleaning:
      // For cleaning from full picker, show ménage sub-options
      final result = await SessionStartSheet.show(context, ActivityType.cleaning);
      if (result == null || !mounted) return;
      switch (result.action) {
        case SessionStartAction.qrScan:
          _openQrScanner();
        case SessionStartAction.buildingPicker:
          await _openBuildingPickerForType(ActivityType.cleaning);
        case SessionStartAction.confirmAdmin:
        case SessionStartAction.changeType:
          break; // shouldn't happen from cleaning sub-sheet
      }
    case ActivityType.maintenance:
      await _openBuildingPickerForType(ActivityType.maintenance);
    case ActivityType.admin:
      await _startAdminSession(activeShift);
  }
}
```

- [ ] **Step 3: Replace `_openBuildingPicker` with `_openBuildingPickerForType`**

Delete the existing `_openBuildingPicker` method (lines 1274-1337) and replace with:

```dart
/// Open building picker and start a session with the given activity type.
Future<void> _openBuildingPickerForType(ActivityType activityType) async {
  final result = await BuildingPickerSheet.show(context);
  if (result == null || !mounted) return;

  final activeShift = ref.read(shiftProvider).activeShift;
  if (activeShift == null) return;

  final sessionResult =
      await ref.read(workSessionProvider.notifier).startSession(
            shiftId: activeShift.id,
            activityType: activityType,
            buildingId: result.buildingId,
            buildingName: result.buildingName,
            apartmentId: result.apartmentId,
            unitNumber: result.unitNumber,
            serverShiftId: activeShift.serverId,
          );

  if (!mounted) return;
  _showSessionResultSnackbar(sessionResult, activityType, result.buildingName, result.unitNumber);
}
```

- [ ] **Step 4: Extract `_startAdminSession` and `_showSessionResultSnackbar` helpers**

```dart
Future<void> _startAdminSession(Shift activeShift) async {
  final result = await ref.read(workSessionProvider.notifier).startSession(
        shiftId: activeShift.id,
        activityType: ActivityType.admin,
        serverShiftId: activeShift.serverId,
      );
  if (!mounted) return;
  _showSessionResultSnackbar(result, ActivityType.admin, null, null);
}

void _showSessionResultSnackbar(
  WorkSessionResult result,
  ActivityType type,
  String? buildingName,
  String? unitNumber,
) {
  if (result.success) {
    String message;
    switch (type) {
      case ActivityType.cleaning:
        message = buildingName != null
            ? 'Ménage démarré — $buildingName${unitNumber != null ? ' ($unitNumber)' : ''}'
            : 'Session ménage démarrée';
      case ActivityType.maintenance:
        message = 'Entretien démarré — ${buildingName ?? ''}'
            '${unitNumber != null ? ' ($unitNumber)' : ''}';
      case ActivityType.admin:
        message = 'Session admin démarrée';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(result.errorMessage ?? 'Erreur de démarrage')),
          ],
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
```

- [ ] **Step 5: Update `_changeActivityType` to use the same flow**

Replace `_changeActivityType` (lines 1402-1428):

```dart
Future<void> _changeActivityType() async {
  final notifier = ref.read(workSessionProvider.notifier);
  final closed = await notifier.changeActivityType();
  if (!closed || !mounted) return;

  // After closing, go through the full picker
  await _startNewSessionFullPicker();
}
```

- [ ] **Step 6: Pass `onStartSession` to `ActiveWorkSessionCard`**

Find where `ActiveWorkSessionCard` is used (around line 1471) and pass the callback:

```dart
ActiveWorkSessionCard(onStartSession: _startNewSession),
```

- [ ] **Step 7: Remove the FAB**

Find the `floatingActionButton:` property (around line 1557-1563) and remove it entirely:

```dart
// REMOVE these lines:
// floatingActionButton: hasActiveShift && !hasActiveWorkSession
//     ? FloatingActionButton.extended(
//         onPressed: _startNewSession,
//         icon: const Icon(Icons.add),
//         label: const Text('Nouvelle session'),
//       )
//     : null,
```

- [ ] **Step 8: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/screens/shift_dashboard_screen.dart`
Expected: No issues

- [ ] **Step 9: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: wire SessionStartSheet, tappable empty state, remove FAB"
```

---

## Chunk 4: QR Auto-Close

### Task 9: Implement QR auto-close in `QrScannerScreen`

**Files:**
- Modify: `gps_tracker/lib/features/work_sessions/screens/qr_scanner_screen.dart:92-165`

- [ ] **Step 1: Replace the active session handling in `_processQrCode`**

Replace lines 92-165 (from `// Check if there's an active session` through to the scan-in section):

```dart
    final notifier = ref.read(workSessionProvider.notifier);
    final activeSession = ref.read(activeWorkSessionProvider);

    if (activeSession != null) {
      // Check if scanning the same studio (scan out)
      final studioCache = ref.read(studioCacheServiceProvider);
      final scannedStudio = await studioCache.lookupByQrCode(qrCode);

      if (scannedStudio != null && scannedStudio.id == activeSession.studioId) {
        // Same studio — scan out
        final result = await notifier.scanOut(qrCode);
        if (!mounted) return;
        final scanResult = _toScanResult(result);
        await ScanResultDialog.show(context, scanResult);
        if (scanResult.success) {
          if (mounted) Navigator.of(context).pop();
        } else {
          _resumeScanner();
        }
        return;
      }

      // Different studio or non-cleaning session — auto-close current and open new
      final closeResult = await notifier.completeSession();
      if (!closeResult.success) {
        if (!mounted) return;
        await ScanResultDialog.show(context, _toScanResult(closeResult));
        _resumeScanner();
        return;
      }

      // Now scan in to the new studio
      final result = await notifier.scanIn(
        qrCode,
        activeShift.id,
        serverShiftId: activeShift.serverId,
      );
      if (!mounted) return;
      final scanResult = _toScanResult(result);
      await ScanResultDialog.show(context, scanResult);
      if (scanResult.success) {
        if (mounted) Navigator.of(context).pop();
      } else {
        _resumeScanner();
      }
      return;
    }

    // No active session — scan in
    final result = await notifier.scanIn(
      qrCode,
      activeShift.id,
      serverShiftId: activeShift.serverId,
    );
    if (!mounted) return;
    final scanResult = _toScanResult(result);
    await ScanResultDialog.show(context, scanResult);
    if (scanResult.success) {
      if (mounted) Navigator.of(context).pop();
    } else {
      _resumeScanner();
    }
```

- [ ] **Step 2: Remove `_showExistingSessionWarning` and `_getQrCodeForSession` methods**

Delete `_showExistingSessionWarning` (lines 230-260) and `_getQrCodeForSession` (lines 222-228). Also delete the `_ExistingSessionAction` enum (line 371).

- [ ] **Step 3: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/screens/qr_scanner_screen.dart`
Expected: No issues

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/screens/qr_scanner_screen.dart
git commit -m "feat: QR auto-close active session without confirmation dialog"
```

---

## Chunk 5: Final Integration + Cleanup

### Task 10: Clean up dashboard — hide LunchBreakButton during active lunch

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

- [ ] **Step 1: Conditionally hide LunchBreakButton when lunch is active**

The lunch break is now shown as a card in `ActiveWorkSessionCard`. The `LunchBreakButton` should still be shown to START lunch (when no lunch is active), but when lunch IS active, the card handles the "end" action — so hide the button.

Find the `LunchBreakButton()` usage (around line 1490) and wrap it:

```dart
if (!ref.watch(isOnLunchProvider))
  const LunchBreakButton(),
```

Wait — actually, looking at the `LunchBreakButton`, when lunch IS active it shows "FIN PAUSE" and when not active it shows "PAUSE DÎNER". Since the card now handles ending lunch, we should only show the button when lunch is NOT active (to start lunch). When lunch IS active, the card handles it.

Replace:
```dart
const LunchBreakButton(),
```
With:
```dart
if (!ref.watch(isOnLunchProvider))
  const LunchBreakButton(),
```

- [ ] **Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/screens/shift_dashboard_screen.dart`
Expected: No issues

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: hide LunchBreakButton when lunch is active (card handles it)"
```

---

### Task 11: Update clock-in flow to use ménage sub-options

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

- [ ] **Step 1: Update the post-clock-in session start**

Find the switch after clock-in (around line 579-591) that currently does:
```dart
case ActivityType.cleaning:
  _openQrScanner();
```

Replace with:
```dart
case ActivityType.cleaning:
  // Show ménage sub-options (court terme QR vs long terme building)
  final subResult = await SessionStartSheet.show(context, ActivityType.cleaning);
  if (subResult == null || !mounted) break;
  switch (subResult.action) {
    case SessionStartAction.qrScan:
      _openQrScanner();
    case SessionStartAction.buildingPicker:
      await _openBuildingPickerForType(ActivityType.cleaning);
    case SessionStartAction.confirmAdmin:
    case SessionStartAction.changeType:
      break;
  }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/screens/shift_dashboard_screen.dart`
Expected: No issues

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: show ménage sub-options (QR/building) at clock-in"
```

---

### Task 12: Full build verification

**Files:** None (verification only)

- [ ] **Step 1: Run full analysis**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues

- [ ] **Step 2: Run tests**

Run: `cd gps_tracker && flutter test`
Expected: All tests pass

- [ ] **Step 3: Final commit if any cleanup needed**

If analysis reveals any issues, fix them and commit.

- [ ] **Step 4: Build iOS to verify**

Run: `cd gps_tracker && flutter build ios --debug --no-codesign`
Expected: BUILD SUCCEEDED
