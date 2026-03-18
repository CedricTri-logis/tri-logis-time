# Colleagues Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow all employees to see which colleagues are currently clocked in, on lunch, or off-shift — plus their active work session — from a new screen in the Flutter app's 3-dot menu.

**Architecture:** Single Supabase RPC (`get_colleagues_status`) returns employee name + work status + active session info. Flutter screen with pull-to-refresh calls this RPC. No polling, no Realtime — simple load-on-open + manual refresh.

**Tech Stack:** PostgreSQL/Supabase (RPC), Dart/Flutter (Riverpod StateNotifier, Material UI)

**Spec:** `docs/superpowers/specs/2026-03-18-colleagues-status-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `supabase/migrations/20260318400000_colleagues_status.sql` | RPC function + grant |
| Create | `gps_tracker/lib/features/colleagues/models/colleague_status.dart` | Data model + enum |
| Create | `gps_tracker/lib/features/colleagues/providers/colleagues_provider.dart` | StateNotifier + providers |
| Create | `gps_tracker/lib/features/colleagues/screens/colleagues_screen.dart` | UI screen |
| Modify | `gps_tracker/lib/features/home/home_screen.dart` | Add menu entry |

---

### Task 1: Supabase RPC — `get_colleagues_status()`

**Files:**
- Create: `supabase/migrations/20260318400000_colleagues_status.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- Colleagues status: returns work status + active session for all active employees
-- Accessible by any authenticated user (company-wide peer visibility)

CREATE OR REPLACE FUNCTION get_colleagues_status()
RETURNS TABLE(
    id UUID,
    full_name TEXT,
    work_status TEXT,
    active_session_type TEXT,
    active_session_location TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ep.id,
        COALESCE(ep.full_name, ep.email)::TEXT as full_name,
        CASE
            WHEN lb_active.id IS NOT NULL THEN 'on-lunch'
            WHEN active_shift.id IS NOT NULL THEN 'on-shift'
            ELSE 'off-shift'
        END::TEXT as work_status,
        ws_active.active_session_type,
        ws_active.active_session_location
    FROM employee_profiles ep
    LEFT JOIN LATERAL (
        SELECT s.id
        FROM shifts s
        WHERE s.employee_id = ep.id AND s.status = 'active'
        LIMIT 1
    ) active_shift ON true
    LEFT JOIN LATERAL (
        SELECT lb.id
        FROM lunch_breaks lb
        WHERE lb.shift_id = active_shift.id AND lb.ended_at IS NULL
        LIMIT 1
    ) lb_active ON active_shift.id IS NOT NULL
    LEFT JOIN LATERAL (
        SELECT
            ws.activity_type::TEXT AS active_session_type,
            CASE
                WHEN ws.activity_type = 'cleaning' THEN
                    st.studio_number || ' — ' || b.name
                WHEN ws.activity_type = 'maintenance' THEN
                    CASE WHEN a.unit_number IS NOT NULL
                        THEN pb.name || ' — ' || a.unit_number
                        ELSE pb.name
                    END
                WHEN ws.activity_type = 'admin' THEN 'Administration'
                ELSE ws.activity_type
            END AS active_session_location
        FROM work_sessions ws
        LEFT JOIN studios st ON st.id = ws.studio_id
        LEFT JOIN buildings b ON b.id = st.building_id
        LEFT JOIN property_buildings pb ON pb.id = ws.building_id
        LEFT JOIN apartments a ON a.id = ws.apartment_id
        WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
        ORDER BY ws.started_at DESC LIMIT 1
    ) ws_active ON true
    WHERE ep.status = 'active'
      AND ep.id != (SELECT auth.uid())
    ORDER BY
        CASE
            WHEN lb_active.id IS NOT NULL THEN 1
            WHEN active_shift.id IS NOT NULL THEN 0
            ELSE 2
        END,
        COALESCE(ep.full_name, ep.email);
END;
$function$;

GRANT EXECUTE ON FUNCTION get_colleagues_status TO authenticated;
```

- [ ] **Step 2: Apply the migration**

Run via Supabase MCP `apply_migration` tool or:
```bash
supabase db push
```

- [ ] **Step 3: Verify the RPC works**

Run via Supabase MCP `execute_sql`:
```sql
SELECT * FROM get_colleagues_status();
```
Expected: Returns rows with `id`, `full_name`, `work_status`, `active_session_type`, `active_session_location`. Employees on-shift appear first, then on-lunch, then off-shift.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260318400000_colleagues_status.sql
git commit -m "feat(db): add get_colleagues_status RPC for peer visibility"
```

---

### Task 2: Flutter Model — `ColleagueStatus`

**Files:**
- Create: `gps_tracker/lib/features/colleagues/models/colleague_status.dart`

- [ ] **Step 1: Create the model file**

```dart
import 'package:flutter/foundation.dart';

enum WorkStatus { onShift, onLunch, offShift }

@immutable
class ColleagueStatus {
  final String id;
  final String fullName;
  final WorkStatus workStatus;
  final String? activeSessionType;
  final String? activeSessionLocation;

  const ColleagueStatus({
    required this.id,
    required this.fullName,
    required this.workStatus,
    this.activeSessionType,
    this.activeSessionLocation,
  });

  factory ColleagueStatus.fromJson(Map<String, dynamic> json) {
    return ColleagueStatus(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      workStatus: _parseWorkStatus(json['work_status'] as String),
      activeSessionType: json['active_session_type'] as String?,
      activeSessionLocation: json['active_session_location'] as String?,
    );
  }

  static WorkStatus _parseWorkStatus(String status) {
    switch (status) {
      case 'on-shift':
        return WorkStatus.onShift;
      case 'on-lunch':
        return WorkStatus.onLunch;
      default:
        return WorkStatus.offShift;
    }
  }

  String get statusLabel {
    switch (workStatus) {
      case WorkStatus.onShift:
        return 'En quart';
      case WorkStatus.onLunch:
        return 'Dîner';
      case WorkStatus.offShift:
        return 'Hors quart';
    }
  }

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
  }

  /// Human-readable session label: "Ménage — 123 Immeuble X"
  String? get sessionLabel {
    if (activeSessionType == null) return null;
    final type = switch (activeSessionType) {
      'cleaning' => 'Ménage',
      'maintenance' => 'Entretien',
      'admin' => 'Administration',
      _ => activeSessionType!,
    };
    if (activeSessionLocation != null && activeSessionType != 'admin') {
      return '$type — $activeSessionLocation';
    }
    return type;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ColleagueStatus &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          workStatus == other.workStatus &&
          activeSessionType == other.activeSessionType;

  @override
  int get hashCode => Object.hash(id, workStatus, activeSessionType);
}
```

- [ ] **Step 2: Verify no compile errors**

```bash
cd gps_tracker && flutter analyze lib/features/colleagues/models/colleague_status.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/colleagues/models/colleague_status.dart
git commit -m "feat(flutter): add ColleagueStatus model"
```

---

### Task 3: Flutter Provider — `ColleaguesProvider`

**Files:**
- Create: `gps_tracker/lib/features/colleagues/providers/colleagues_provider.dart`

**Reference:** Follow the pattern from `gps_tracker/lib/features/dashboard/providers/team_dashboard_provider.dart` — StateNotifier with load + refresh.

- [ ] **Step 1: Create the provider file**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../models/colleague_status.dart';

class ColleaguesState {
  final List<ColleagueStatus> colleagues;
  final bool isLoading;
  final String? error;

  const ColleaguesState({
    this.colleagues = const [],
    this.isLoading = false,
    this.error,
  });

  ColleaguesState copyWith({
    List<ColleagueStatus>? colleagues,
    bool? isLoading,
    String? error,
  }) {
    return ColleaguesState(
      colleagues: colleagues ?? this.colleagues,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  int get onShiftCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.onShift).length;
  int get onLunchCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.onLunch).length;
  int get offShiftCount =>
      colleagues.where((c) => c.workStatus == WorkStatus.offShift).length;
}

class ColleaguesNotifier extends StateNotifier<ColleaguesState> {
  final SupabaseClient _supabase;

  ColleaguesNotifier(this._supabase) : super(const ColleaguesState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _supabase.rpc('get_colleagues_status');
      final colleagues = (response as List<dynamic>)
          .map((json) =>
              ColleagueStatus.fromJson(json as Map<String, dynamic>))
          .toList();
      state = state.copyWith(colleagues: colleagues, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de charger la liste des collègues.',
      );
    }
  }

  Future<void> refresh() => load();
}

final colleaguesProvider =
    StateNotifierProvider.autoDispose<ColleaguesNotifier, ColleaguesState>(
  (ref) => ColleaguesNotifier(ref.watch(supabaseClientProvider)),
);
```

- [ ] **Step 2: Verify no compile errors**

```bash
cd gps_tracker && flutter analyze lib/features/colleagues/providers/colleagues_provider.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/colleagues/providers/colleagues_provider.dart
git commit -m "feat(flutter): add ColleaguesProvider with load + pull-to-refresh"
```

---

### Task 4: Flutter Screen — `ColleaguesScreen`

**Files:**
- Create: `gps_tracker/lib/features/colleagues/screens/colleagues_screen.dart`

**Reference:** Follow the list pattern from `gps_tracker/lib/features/dashboard/screens/team_dashboard_screen.dart` — ConsumerWidget + CustomScrollView.

- [ ] **Step 1: Create the screen file**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/colleague_status.dart';
import '../providers/colleagues_provider.dart';

class ColleaguesScreen extends ConsumerWidget {
  const ColleaguesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(colleaguesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Collègues'),
      ),
      body: state.isLoading && state.colleagues.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : state.error != null && state.colleagues.isEmpty
              ? _ErrorView(
                  message: state.error!,
                  onRetry: () =>
                      ref.read(colleaguesProvider.notifier).refresh(),
                )
              : RefreshIndicator(
                  onRefresh: () =>
                      ref.read(colleaguesProvider.notifier).refresh(),
                  child: state.colleagues.isEmpty
                      ? const _EmptyView()
                      : CustomScrollView(
                          slivers: [
                            SliverToBoxAdapter(
                              child: _SummaryBar(state: state),
                            ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) => _ColleagueTile(
                                  colleague: state.colleagues[index],
                                ),
                                childCount: state.colleagues.length,
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 24),
                            ),
                          ],
                        ),
                ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final ColleaguesState state;
  const _SummaryBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '${state.onShiftCount} en quart · '
        '${state.onLunchCount} en dîner · '
        '${state.offShiftCount} hors quart',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
      ),
    );
  }
}

class _ColleagueTile extends StatelessWidget {
  final ColleagueStatus colleague;
  const _ColleagueTile({required this.colleague});

  @override
  Widget build(BuildContext context) {
    final (badgeColor, badgeTextColor) = switch (colleague.workStatus) {
      WorkStatus.onShift => (Colors.green[100]!, Colors.green[800]!),
      WorkStatus.onLunch => (Colors.orange[100]!, Colors.orange[800]!),
      WorkStatus.offShift => (Colors.grey[200]!, Colors.grey[600]!),
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colleague.workStatus == WorkStatus.offShift
            ? Colors.grey[300]
            : Colors.blue[100],
        child: Text(
          colleague.initials,
          style: TextStyle(
            color: colleague.workStatus == WorkStatus.offShift
                ? Colors.grey[600]
                : Colors.blue[800],
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      title: Text(colleague.fullName),
      subtitle: colleague.sessionLabel != null
          ? Text(
              colleague.sessionLabel!,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            )
          : null,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: badgeColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          colleague.statusLabel,
          style: TextStyle(
            color: badgeTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.people_outline, size: 64, color: Colors.grey[300]),
        const SizedBox(height: 16),
        Text(
          'Aucun collègue trouvé',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[500], fontSize: 16),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Verify no compile errors**

```bash
cd gps_tracker && flutter analyze lib/features/colleagues/
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/colleagues/screens/colleagues_screen.dart
git commit -m "feat(flutter): add ColleaguesScreen with summary bar and status badges"
```

---

### Task 5: Menu Integration — HomeScreen

**Files:**
- Modify: `gps_tracker/lib/features/home/home_screen.dart`

**Reference:** The existing PopupMenuButton pattern in `home_screen.dart`. Add a `colleagues` menu item before the divider/sign-out, available to ALL roles.

- [ ] **Step 1: Add import at the top of the file**

Add this import alongside the existing feature imports:
```dart
import '../colleagues/screens/colleagues_screen.dart';
```

- [ ] **Step 2: Add the menu item to the PopupMenuButton `itemBuilder`**

In BOTH the employee and manager menu builders, add before the `PopupMenuDivider`:
```dart
const PopupMenuItem(
  value: 'colleagues',
  child: Row(
    children: [
      Icon(Icons.people_outlined, color: TriLogisColors.red),
      SizedBox(width: 12),
      Text('Collègues'),
    ],
  ),
),
```

- [ ] **Step 3: Add the navigation case to `onSelected`**

In the `onSelected` switch statement, add:
```dart
case 'colleagues':
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const ColleaguesScreen()),
  );
  break;
```

- [ ] **Step 4: Verify no compile errors**

```bash
cd gps_tracker && flutter analyze lib/features/home/home_screen.dart
```
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/home/home_screen.dart
git commit -m "feat(flutter): add Collègues entry to 3-dot menu for all roles"
```

---

### Task 6: Final Verification

- [ ] **Step 1: Run full flutter analyze**

```bash
cd gps_tracker && flutter analyze
```
Expected: No issues found.

- [ ] **Step 2: Manual smoke test**

1. Open the app as a regular employee
2. Tap the 3-dot menu → "Collègues" should appear
3. Tap "Collègues" → screen shows with summary bar + employee list
4. Each employee shows name + status badge (green/orange/grey)
5. Employees with active sessions show subtitle (e.g. "Ménage — 123 Immeuble")
6. Pull-to-refresh updates the list
7. Open the app as a manager → "Collègues" also appears in the menu

- [ ] **Step 3: Final commit if any fixes needed**
