# Contract: UI Widgets

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Type**: Widget Interface Contract

---

## Overview

This document defines the interface contracts for tracking-related UI widgets.

---

## TrackingStatusIndicator

### File Location
`lib/features/tracking/widgets/tracking_status_indicator.dart`

### Purpose
Display current tracking status with visual feedback.

### Interface

```dart
class TrackingStatusIndicator extends ConsumerWidget {
  /// Optional compact mode for use in cards.
  final bool compact;

  /// Whether to show point count.
  final bool showPointCount;

  const TrackingStatusIndicator({
    super.key,
    this.compact = false,
    this.showPointCount = true,
  });
}
```

### Visual States

| Status | Icon | Color | Label |
|--------|------|-------|-------|
| `stopped` | `location_off` | Grey | "Not Tracking" |
| `starting` | `location_searching` | Orange (animated) | "Starting..." |
| `running` | `location_on` | Green (pulsing) | "Tracking Active" |
| `paused` | `location_disabled` | Orange | "GPS Unavailable" |
| `error` | `error` | Red | "Tracking Error" |

### Compact Mode
- Icon only, 24x24 size
- Tooltip shows full status

### Full Mode
- Icon + Label
- Optional point count badge
- Optional last update time

---

## RouteMapWidget

### File Location
`lib/features/tracking/widgets/route_map_widget.dart`

### Purpose
Display GPS points as a route on an interactive map.

### Interface

```dart
class RouteMapWidget extends StatelessWidget {
  /// GPS points to display.
  final List<RoutePoint> points;

  /// Whether to show individual point markers.
  final bool showMarkers;

  /// Whether to show accuracy indicators on markers.
  final bool showAccuracy;

  /// Callback when a point is tapped.
  final void Function(RoutePoint point)? onPointTap;

  /// Initial zoom level (default: auto-fit to bounds).
  final double? initialZoom;

  const RouteMapWidget({
    super.key,
    required this.points,
    this.showMarkers = true,
    this.showAccuracy = true,
    this.onPointTap,
    this.initialZoom,
  });
}
```

### Visual Elements

| Element | Style | Description |
|---------|-------|-------------|
| Route line | Blue, 3px width | Connects points chronologically |
| High-accuracy marker | Green circle | Points with accuracy <= 50m |
| Medium-accuracy marker | Yellow circle | Points with accuracy 50-100m |
| Low-accuracy marker | Orange circle | Points with accuracy > 100m |
| Start marker | Green flag | First point |
| End marker | Red flag | Last point |

### Map Provider
Uses `flutter_map` with OpenStreetMap tiles:
```dart
TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.gps_tracker.app',
)
```

### Interaction
- Pinch to zoom
- Pan to scroll
- Tap marker to show timestamp (via `onPointTap`)

---

## GpsPointMarker

### File Location
`lib/features/tracking/widgets/gps_point_marker.dart`

### Purpose
Individual GPS point marker for map display.

### Interface

```dart
class GpsPointMarker extends StatelessWidget {
  /// The GPS point to display.
  final RoutePoint point;

  /// Marker size in logical pixels.
  final double size;

  /// Whether this is the start point.
  final bool isStart;

  /// Whether this is the end point.
  final bool isEnd;

  /// Callback when tapped.
  final VoidCallback? onTap;

  const GpsPointMarker({
    super.key,
    required this.point,
    this.size = 12,
    this.isStart = false,
    this.isEnd = false,
    this.onTap,
  });
}
```

### Color Logic

```dart
Color get markerColor {
  if (isStart) return Colors.green;
  if (isEnd) return Colors.red;
  if (point.isLowAccuracy) return Colors.orange;
  if (point.isHighAccuracy) return Colors.green;
  return Colors.yellow; // Medium accuracy
}
```

---

## PointDetailSheet

### File Location
`lib/features/tracking/widgets/point_detail_sheet.dart`

### Purpose
Bottom sheet showing details for a selected GPS point.

### Interface

```dart
class PointDetailSheet extends StatelessWidget {
  final RoutePoint point;

  const PointDetailSheet({
    super.key,
    required this.point,
  });

  /// Show as modal bottom sheet.
  static Future<void> show(BuildContext context, RoutePoint point) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => PointDetailSheet(point: point),
    );
  }
}
```

### Content

| Field | Format | Example |
|-------|--------|---------|
| Time | HH:MM:SS | "14:32:45" |
| Date | Weekday, Month Day | "Monday, Jan 8" |
| Coordinates | DD.DDDDDD° N/S, DD.DDDDDD° E/W | "37.7749° N, 122.4194° W" |
| Accuracy | X meters (with quality label) | "15 meters (High)" |

---

## RouteStatsCard

### File Location
`lib/features/tracking/widgets/route_stats_card.dart`

### Purpose
Display summary statistics for a route.

### Interface

```dart
class RouteStatsCard extends StatelessWidget {
  final RouteStats stats;

  const RouteStatsCard({
    super.key,
    required this.stats,
  });
}
```

### Content

| Statistic | Icon | Format |
|-----------|------|--------|
| Total Points | `pin_drop` | "48 points" |
| Distance | `straighten` | "12.5 km" |
| Duration | `timer` | "4h 32m" |
| Accuracy | `gps_fixed` | "95% high accuracy" |

---

## Integration Points

### ShiftDashboardScreen

Add `TrackingStatusIndicator` to `ShiftStatusCard`:

```dart
// In shift_status_card.dart
if (shift.isActive) ...[
  const SizedBox(height: 8),
  const TrackingStatusIndicator(compact: true),
]
```

### ShiftDetailScreen

Add route map for completed shifts:

```dart
// In shift_detail_screen.dart
Consumer(
  builder: (context, ref, _) {
    final routeAsync = ref.watch(routeProvider(shift.id));

    return routeAsync.when(
      data: (points) => Column(
        children: [
          RouteStatsCard(stats: ref.watch(routeStatsProvider(points))),
          const SizedBox(height: 16),
          SizedBox(
            height: 300,
            child: RouteMapWidget(
              points: points,
              onPointTap: (point) => PointDetailSheet.show(context, point),
            ),
          ),
        ],
      ),
      loading: () => const CircularProgressIndicator(),
      error: (e, _) => Text('Error loading route: $e'),
    );
  },
)
```

---

## Accessibility

| Widget | A11y Feature |
|--------|--------------|
| TrackingStatusIndicator | Semantic label describing status |
| RouteMapWidget | Not accessible (decorative) |
| GpsPointMarker | Tap target >= 48px |
| PointDetailSheet | Focus management on open |
| RouteStatsCard | Labels for all values |

---

## Theme Integration

All widgets should use theme colors:

```dart
final colorScheme = Theme.of(context).colorScheme;
final textTheme = Theme.of(context).textTheme;

// Status colors
final successColor = colorScheme.primary;
final warningColor = Colors.orange;
final errorColor = colorScheme.error;
```
