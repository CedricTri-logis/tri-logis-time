# Type Contracts: Mileage Tracking

## Dart Models (Mobile)

### Trip

```dart
class Trip {
  final String id;
  final String shiftId;
  final String employeeId;
  final DateTime startedAt;
  final DateTime endedAt;
  final double startLatitude;
  final double startLongitude;
  final String? startAddress;       // Lazy reverse-geocoded
  final String? startLocationId;    // Matched geofence (nullable)
  final String? startLocationName;  // From locations table
  final double endLatitude;
  final double endLongitude;
  final String? endAddress;
  final String? endLocationId;
  final String? endLocationName;
  final double distanceKm;
  final int durationMinutes;
  final TripClassification classification;
  final double confidenceScore;     // 0.0-1.0
  final int gpsPointCount;
  final int lowAccuracySegments;
  final TripDetectionMethod detectionMethod;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Computed
  double get estimatedReimbursement => /* rate * distanceKm */;
  bool get isLowConfidence => confidenceScore < 0.7;
  bool get isBusiness => classification == TripClassification.business;
}

enum TripClassification { business, personal }
enum TripDetectionMethod { auto, manual }
```

### MileageSummary

```dart
class MileageSummary {
  final double totalDistanceKm;
  final double businessDistanceKm;
  final double personalDistanceKm;
  final int tripCount;
  final int businessTripCount;
  final int personalTripCount;
  final double estimatedReimbursement;
  final double ratePerKmUsed;
  final String rateSource;
  final double ytdBusinessKm;        // Year-to-date for tier calc
}
```

### ReimbursementRate

```dart
class ReimbursementRate {
  final String id;
  final double ratePerKm;
  final int? thresholdKm;            // e.g., 5000
  final double? rateAfterThreshold;  // e.g., 0.66
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final String rateSource;           // 'cra' | 'custom'
  final String? notes;
  final DateTime createdAt;

  // Computed
  double calculateReimbursement(double km, double ytdKm) {
    if (thresholdKm == null || rateAfterThreshold == null) {
      return km * ratePerKm;
    }
    final kmAtBaseRate = (thresholdKm! - ytdKm).clamp(0, km);
    final kmAtReducedRate = km - kmAtBaseRate;
    return (kmAtBaseRate * ratePerKm) + (kmAtReducedRate * rateAfterThreshold!);
  }
}
```

### LocalTrip (SQLCipher)

```dart
class LocalTrip {
  final String id;
  final String shiftId;
  final String employeeId;
  final String startedAt;          // ISO 8601
  final String endedAt;
  final double startLatitude;
  final double startLongitude;
  final String? startAddress;
  final double endLatitude;
  final double endLongitude;
  final String? endAddress;
  final double distanceKm;
  final int durationMinutes;
  final String classification;     // 'business' | 'personal'
  final double confidenceScore;
  final int gpsPointCount;
  final bool synced;
  final String createdAt;

  Trip toTrip() => /* convert to Trip model */;
  Map<String, dynamic> toMap() => /* SQLite row */;
  factory LocalTrip.fromMap(Map<String, dynamic> map) => /* from SQLite row */;
  factory LocalTrip.fromTrip(Trip trip) => /* from server Trip */;
}
```

---

## TypeScript Types (Dashboard)

### Trip

```typescript
export interface Trip {
  id: string;
  shift_id: string;
  employee_id: string;
  started_at: string;              // ISO 8601
  ended_at: string;
  start_latitude: number;
  start_longitude: number;
  start_address: string | null;
  start_location_id: string | null;
  end_latitude: number;
  end_longitude: number;
  end_address: string | null;
  end_location_id: string | null;
  distance_km: number;
  duration_minutes: number;
  classification: 'business' | 'personal';
  confidence_score: number;
  gps_point_count: number;
  low_accuracy_segments: number;
  detection_method: 'auto' | 'manual';
  created_at: string;
  updated_at: string;

  // Joined fields (optional, from expanded queries)
  employee?: {
    id: string;
    name: string;
  };
  start_location?: {
    id: string;
    name: string;
  };
  end_location?: {
    id: string;
    name: string;
  };
}
```

### MileageSummary

```typescript
export interface MileageSummary {
  total_distance_km: number;
  business_distance_km: number;
  personal_distance_km: number;
  trip_count: number;
  business_trip_count: number;
  personal_trip_count: number;
  estimated_reimbursement: number;
  rate_per_km_used: number;
  rate_source: string;
  ytd_business_km: number;
}
```

### TeamMileageSummary

```typescript
export interface TeamMileageSummary {
  employee_id: string;
  employee_name: string;
  total_distance_km: number;
  business_distance_km: number;
  trip_count: number;
  estimated_reimbursement: number;
  avg_daily_km: number;
}
```

### ReimbursementRate

```typescript
export interface ReimbursementRate {
  id: string;
  rate_per_km: number;
  threshold_km: number | null;
  rate_after_threshold: number | null;
  effective_from: string;          // DATE (YYYY-MM-DD)
  effective_to: string | null;
  rate_source: 'cra' | 'custom';
  notes: string | null;
  created_by: string | null;
  created_at: string;
}
```

### MileageReport

```typescript
export interface MileageReport {
  id: string;
  employee_id: string;
  period_start: string;
  period_end: string;
  total_distance_km: number;
  business_distance_km: number;
  personal_distance_km: number;
  trip_count: number;
  business_trip_count: number;
  total_reimbursement: number;
  rate_per_km_used: number;
  rate_source_used: string;
  file_path: string | null;
  file_format: 'pdf' | 'csv';
  generated_at: string;
  created_at: string;
}
```

---

## Zod Validation Schemas (Dashboard)

### Rate Config Form

```typescript
import { z } from 'zod';

export const rateConfigSchema = z.object({
  rate_per_km: z.number().positive().max(5),
  threshold_km: z.number().int().positive().optional(),
  rate_after_threshold: z.number().positive().max(5).optional(),
  effective_from: z.string().date(),
  rate_source: z.enum(['cra', 'custom']),
  notes: z.string().max(500).optional(),
});

export type RateConfigFormValues = z.infer<typeof rateConfigSchema>;
```

### Mileage Filters

```typescript
export const mileageFiltersSchema = z.object({
  period_start: z.string().date(),
  period_end: z.string().date(),
  employee_id: z.string().uuid().optional(),
  classification: z.enum(['all', 'business', 'personal']).default('all'),
});

export type MileageFiltersValues = z.infer<typeof mileageFiltersSchema>;
```

### Report Generation

```typescript
export const reportGenerationSchema = z.object({
  period_start: z.string().date(),
  period_end: z.string().date(),
  format: z.enum(['pdf', 'csv']).default('pdf'),
  include_personal: z.boolean().default(false),
});

export type ReportGenerationValues = z.infer<typeof reportGenerationSchema>;
```
