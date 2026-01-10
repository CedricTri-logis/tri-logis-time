# Research: Employee History

**Feature**: 006-employee-history | **Date**: 2026-01-10

## Overview

This document captures technical research and decisions for the Employee History feature, resolving all NEEDS CLARIFICATION items from the plan and establishing best practices for key dependencies.

---

## Decision 1: Manager-Employee Supervision Model

**Decision**: Use a dedicated `employee_supervisors` junction table with effective dates

**Rationale**:
- Supports flexible team structures including matrix reporting
- Enables historical tracking of supervision relationships (who supervised whom when)
- Allows a manager to supervise multiple employees, and an employee to have multiple managers
- Effective dates (`effective_from`, `effective_to`) enable querying "who was supervised by whom at a specific time"

**Alternatives Considered**:
- Direct `manager_id` FK on `employee_profiles`: Rejected because it only supports single manager per employee, no history
- Role-based groups table: Rejected as over-engineered for current needs

**Schema Design**:
```sql
CREATE TABLE employee_supervisors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    manager_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    supervision_type TEXT NOT NULL DEFAULT 'direct'
        CHECK (supervision_type IN ('direct', 'matrix', 'temporary')),
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT no_self_supervision CHECK (manager_id != employee_id),
    CONSTRAINT valid_date_range CHECK (effective_to IS NULL OR effective_to > effective_from)
);
```

---

## Decision 2: Role-Based Access Control

**Decision**: Add `role` enum field to `employee_profiles` table with values: 'employee', 'manager', 'admin'

**Rationale**:
- Simple and sufficient for current requirements
- Easily extensible if more roles needed later
- Consistent with spec clarification Q&A
- Integrates with existing RLS pattern

**Implementation**:
```sql
ALTER TABLE employee_profiles
ADD COLUMN role TEXT NOT NULL DEFAULT 'employee'
    CHECK (role IN ('employee', 'manager', 'admin'));
```

**Flutter Model Update**:
```dart
enum UserRole {
  employee('employee'),
  manager('manager'),
  admin('admin');

  final String value;
  const UserRole(this.value);

  static UserRole fromString(String value) =>
    UserRole.values.firstWhere((e) => e.value == value, orElse: () => UserRole.employee);
}
```

---

## Decision 3: RLS Policies for Manager Access

**Decision**: Create separate RLS policies allowing managers to view supervised employees' data

**Rationale**:
- Supabase RLS is the established pattern in this project
- Policies can check against `employee_supervisors` table
- Keeps authorization logic in database, not application code
- Existing patterns in `001_initial_schema.sql` provide template

**Policy Design**:
```sql
-- Managers can view profiles of supervised employees
CREATE POLICY "Managers can view supervised employee profiles"
ON employee_profiles FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = employee_profiles.id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- Managers can view shifts of supervised employees
CREATE POLICY "Managers can view supervised employee shifts"
ON shifts FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = shifts.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
```

**Reference**: [Supabase RLS Documentation](https://supabase.com/docs/guides/auth/row-level-security)

---

## Decision 4: Map Provider - Google Maps Flutter

**Decision**: Use `google_maps_flutter` package for GPS route visualization

**Rationale**:
- Specified in feature spec clarifications
- Official Google package with strong Flutter support
- Supports marker clustering (important for 100+ GPS points)
- Free tier available with reasonable limits

**Best Practices** (from research):
1. Keep the map widget stable - update only overlays (markers, polylines)
2. Use marker clustering for performance when displaying many points
3. Keep marker icon sizes under 64x64px
4. Debounce camera events to avoid excessive API calls
5. Must include Google Maps attribution in legal notices

**Setup Requirements**:
- Enable Maps SDK for Android & iOS in Google Cloud Console
- Obtain API key and restrict to your app's package/bundle ID
- Set Android minSdkVersion to 21, iOS minimum to 14.0

**pubspec.yaml Addition**:
```yaml
dependencies:
  google_maps_flutter: ^2.5.0
```

**Platform Config**:
- Android: Add API key to `android/app/src/main/AndroidManifest.xml`
- iOS: Add API key to `ios/Runner/AppDelegate.swift`

**Reference**: [Google Maps Flutter Documentation](https://developers.google.com/maps/flutter-package/overview)

---

## Decision 5: PDF Generation - pdf Package

**Decision**: Use `pdf` package (DavBfr/dart_pdf) for client-side PDF generation

**Rationale**:
- Specified in feature spec clarifications
- Pure Dart implementation, no native dependencies
- Works on all platforms (iOS, Android, web)
- Open source with active maintenance
- Companion `printing` package for share/print operations

**Best Practices**:
1. Structure PDF with `Document`, `Page`, and widgets
2. Use `PdfPageFormat.a4` for standard reports
3. Include table widgets for shift data presentation
4. Generate PDF in isolate for large documents (background processing)

**pubspec.yaml Addition**:
```yaml
dependencies:
  pdf: ^3.10.0
  printing: ^5.12.0  # For sharing/printing
```

**Basic Structure**:
```dart
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> generateShiftReport(List<Shift> shifts) async {
  final pdf = pw.Document();

  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) => pw.Column(
        children: [
          pw.Header(text: 'Shift History Report'),
          pw.Table.fromTextArray(
            headers: ['Date', 'Clock In', 'Clock Out', 'Duration'],
            data: shifts.map((s) => [
              formatDate(s.clockedInAt),
              formatTime(s.clockedInAt),
              formatTime(s.clockedOutAt),
              formatDuration(s.duration),
            ]).toList(),
          ),
        ],
      ),
    ),
  );

  return pdf.save();
}
```

**Reference**: [pdf Package](https://pub.dev/packages/pdf)

---

## Decision 6: CSV Export - csv Package

**Decision**: Use `csv` package with `path_provider` for file saving and `share_plus` for sharing

**Rationale**:
- Simple, well-maintained package
- Pure Dart implementation
- `ListToCsvConverter` provides clean API for data conversion
- Compatible with existing `path_provider` dependency

**pubspec.yaml Addition**:
```yaml
dependencies:
  csv: ^5.1.0
  share_plus: ^7.2.0  # For sharing exported files
```

**Implementation Pattern**:
```dart
import 'package:csv/csv.dart';
import 'dart:io';

Future<File> exportShiftsToCsv(List<Shift> shifts) async {
  final headers = ['Employee', 'Date', 'Clock In', 'Clock Out', 'Duration', 'Location'];

  final rows = shifts.map((s) => [
    s.employeeName,
    formatDate(s.clockedInAt),
    formatTime(s.clockedInAt),
    formatTime(s.clockedOutAt),
    formatDuration(s.duration),
    formatLocation(s.clockInLocation),
  ]).toList();

  final csvData = const ListToCsvConverter().convert([headers, ...rows]);

  final directory = await getApplicationDocumentsDirectory();
  final file = File('${directory.path}/shift_export_${DateTime.now().toIso8601String()}.csv');
  return file.writeAsString(csvData);
}
```

**Reference**: [csv Package](https://pub.dev/packages/csv)

---

## Decision 7: Timezone Display Strategy

**Decision**: Store all timestamps in UTC, display in viewer's local timezone with indicator

**Rationale**:
- Consistent with existing project pattern (shifts store UTC)
- Avoids timezone confusion when viewing historical data
- Flutter's `intl` package handles formatting with timezone
- UI should clearly show timezone to prevent misinterpretation

**Implementation**:
```dart
// Display time with timezone indicator
String formatTimeWithTimezone(DateTime utcTime) {
  final localTime = utcTime.toLocal();
  final timezone = localTime.timeZoneName;
  return '${DateFormat.jm().format(localTime)} ($timezone)';
}
```

---

## Decision 8: Performance Optimization Strategy

**Decision**: Implement pagination, caching, and lazy loading for large datasets

**Rationale**:
- Managers may supervise 50+ employees with years of shift data
- Performance criteria require <3s load, <2s filter updates
- Mobile devices have memory constraints

**Strategies**:
1. **Pagination**: Load shifts in batches of 50, infinite scroll
2. **Date Range Limits**: Default to last 30 days, allow expansion
3. **Statistics Caching**: Calculate and cache summary stats
4. **Map Clustering**: Use marker clustering for GPS points

**Query Optimization**:
```sql
-- Index for efficient date range filtering
CREATE INDEX idx_shifts_employee_date ON shifts(employee_id, clocked_in_at DESC);

-- Pagination function
CREATE FUNCTION get_employee_shifts_paginated(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE(...) AS $$
...
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Decision 9: Offline Support Strategy

**Decision**: History viewing works offline from local cache; export available for cached data only

**Rationale**:
- Consistent with Constitution IV: Offline-First Architecture
- LocalDatabase (SQLCipher) already stores shifts and GPS points
- Read-only operations don't require sync

**Behavior**:
1. History fetched from server when online, cached locally
2. When offline, show cached data with "last synced" indicator
3. Export functionality works with available cached data
4. Statistics calculated from available data with accuracy indicator

---

## Decision 10: New Dependencies Summary

**Dependencies to Add**:
```yaml
dependencies:
  google_maps_flutter: ^2.5.0  # Map display
  pdf: ^3.10.0                  # PDF generation
  printing: ^5.12.0             # PDF sharing/printing
  csv: ^5.1.0                   # CSV export
  share_plus: ^7.2.0            # File sharing
```

**Existing Dependencies Leveraged**:
- `flutter_riverpod: ^2.5.0` - State management
- `supabase_flutter: ^2.12.0` - Backend
- `sqflite_sqlcipher: ^3.1.0` - Local encrypted storage
- `path_provider: ^2.1.5` - File system access
- `geolocator: ^12.0.0` - Location data models
- `intl` (via flutter) - Date/time formatting

---

## Research Sources

- [Supabase Row Level Security](https://supabase.com/docs/guides/auth/row-level-security)
- [Google Maps Flutter Package](https://pub.dev/packages/google_maps_flutter)
- [Google Maps Flutter Best Practices](https://developers.google.com/maps/flutter-package/overview)
- [pdf Package](https://pub.dev/packages/pdf)
- [csv Package](https://pub.dev/packages/csv)
