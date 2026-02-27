// Location Geofences & Shift Segmentation Types
// Types for the location management and timeline features (Spec 015)

/**
 * Location type classification for workplace geofences
 */
export type LocationType = 'office' | 'building' | 'vendor' | 'home' | 'cafe_restaurant' | 'other';

/**
 * Segment type for timeline visualization
 */
export type SegmentType = 'matched' | 'travel' | 'unmatched';

/**
 * Location row from database/RPC
 */
export interface LocationRow {
  id: string;
  name: string;
  location_type: LocationType;
  latitude: number;
  longitude: number;
  radius_meters: number;
  address: string | null;
  notes: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  total_count?: number;
}

/**
 * Frontend location type with camelCase properties
 */
export interface Location {
  id: string;
  name: string;
  locationType: LocationType;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  address: string | null;
  notes: string | null;
  isActive: boolean;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * Location match row from RPC
 */
export interface LocationMatchRow {
  gps_point_id: string;
  gps_latitude: number;
  gps_longitude: number;
  captured_at: string;
  location_id: string | null;
  location_name: string | null;
  location_type: LocationType | null;
  distance_meters: number | null;
  confidence_score: number | null;
}

/**
 * Frontend location match type
 */
export interface LocationMatch {
  gpsPointId: string;
  gpsLatitude: number;
  gpsLongitude: number;
  capturedAt: Date;
  locationId: string | null;
  locationName: string | null;
  locationType: LocationType | null;
  distanceMeters: number | null;
  confidenceScore: number | null;
}

/**
 * Timeline segment row from RPC
 */
export interface TimelineSegmentRow {
  segment_index: number;
  segment_type: SegmentType;
  start_time: string;
  end_time: string;
  duration_seconds: number;
  point_count: number;
  location_id: string | null;
  location_name: string | null;
  location_type: LocationType | null;
  avg_confidence: number | null;
}

/**
 * Frontend timeline segment type
 */
export interface TimelineSegment {
  segmentIndex: number;
  segmentType: SegmentType;
  startTime: Date;
  endTime: Date;
  durationSeconds: number;
  pointCount: number;
  locationId: string | null;
  locationName: string | null;
  locationType: LocationType | null;
  avgConfidence: number | null;
}

/**
 * Timeline summary for shift statistics
 */
export interface TimelineSummary {
  shiftId: string;
  totalDurationSeconds: number;
  totalGpsPoints: number;
  matchedDurationSeconds: number;
  matchedPercentage: number;
  travelDurationSeconds: number;
  travelPercentage: number;
  unmatchedDurationSeconds: number;
  unmatchedPercentage: number;
  byLocationType: LocationTypeSummary[];
}

/**
 * Duration breakdown by location type
 */
export interface LocationTypeSummary {
  locationType: LocationType;
  durationSeconds: number;
  percentage: number;
  locations: LocationDurationSummary[];
}

/**
 * Individual location duration within a type
 */
export interface LocationDurationSummary {
  locationId: string;
  locationName: string;
  durationSeconds: number;
}

/**
 * Bulk insert result row from RPC
 */
export interface BulkInsertResultRow {
  id: string | null;
  name: string;
  success: boolean;
  error_message: string | null;
}

/**
 * Frontend bulk insert result
 */
export interface BulkInsertResult {
  id: string | null;
  name: string;
  success: boolean;
  errorMessage: string | null;
}

/**
 * Check shift matches result row from RPC
 */
export interface ShiftMatchesCheckRow {
  has_matches: boolean;
  match_count: number;
  matched_at: string | null;
}

/**
 * Frontend shift matches check result
 */
export interface ShiftMatchesCheck {
  hasMatches: boolean;
  matchCount: number;
  matchedAt: Date | null;
}

/**
 * Location form data for create/edit
 */
export interface LocationFormData {
  name: string;
  locationType: LocationType;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  address: string | null;
  notes: string | null;
  isActive: boolean;
}

/**
 * CSV import row (pre-validation)
 */
export interface LocationCsvRow {
  name: string;
  location_type: string;
  latitude: string | number;
  longitude: string | number;
  radius_meters?: string | number;
  address?: string;
  notes?: string;
  is_active?: string | boolean;
}

/**
 * CSV import validation result
 */
export interface CsvValidationResult {
  valid: boolean;
  row: LocationCsvRow;
  rowIndex: number;
  errors: string[];
  data?: LocationFormData;
}

/**
 * CSV import summary
 */
export interface CsvImportSummary {
  status: 'success' | 'partial' | 'failed';
  totalRows: number;
  importedCount: number;
  skippedCount: number;
  failedCount: number;
  skippedRows: Array<{ rowIndex: number; errors: string[] }>;
  failedRows: Array<{ rowIndex: number; error: string }>;
}

// =============================================================================
// Transform Functions
// =============================================================================

/**
 * Transform RPC row to frontend location type
 */
export function transformLocationRow(row: LocationRow): Location {
  return {
    id: row.id,
    name: row.name,
    locationType: row.location_type,
    latitude: row.latitude,
    longitude: row.longitude,
    radiusMeters: row.radius_meters,
    address: row.address,
    notes: row.notes,
    isActive: row.is_active,
    createdAt: new Date(row.created_at),
    updatedAt: new Date(row.updated_at),
  };
}

/**
 * Transform RPC row to frontend location match type
 */
export function transformLocationMatchRow(row: LocationMatchRow): LocationMatch {
  return {
    gpsPointId: row.gps_point_id,
    gpsLatitude: row.gps_latitude,
    gpsLongitude: row.gps_longitude,
    capturedAt: new Date(row.captured_at),
    locationId: row.location_id,
    locationName: row.location_name,
    locationType: row.location_type,
    distanceMeters: row.distance_meters,
    confidenceScore: row.confidence_score,
  };
}

/**
 * Transform RPC row to frontend timeline segment type
 */
export function transformTimelineSegmentRow(
  row: TimelineSegmentRow
): TimelineSegment {
  return {
    segmentIndex: row.segment_index,
    segmentType: row.segment_type,
    startTime: new Date(row.start_time),
    endTime: new Date(row.end_time),
    durationSeconds: row.duration_seconds,
    pointCount: row.point_count,
    locationId: row.location_id,
    locationName: row.location_name,
    locationType: row.location_type,
    avgConfidence: row.avg_confidence,
  };
}

/**
 * Transform RPC row to frontend bulk insert result
 */
export function transformBulkInsertResultRow(
  row: BulkInsertResultRow
): BulkInsertResult {
  return {
    id: row.id,
    name: row.name,
    success: row.success,
    errorMessage: row.error_message,
  };
}

/**
 * Transform RPC row to frontend shift matches check result
 */
export function transformShiftMatchesCheckRow(
  row: ShiftMatchesCheckRow
): ShiftMatchesCheck {
  return {
    hasMatches: row.has_matches,
    matchCount: row.match_count,
    matchedAt: row.matched_at ? new Date(row.matched_at) : null,
  };
}

/**
 * Compute timeline summary from segments
 */
export function computeTimelineSummary(
  shiftId: string,
  segments: TimelineSegment[]
): TimelineSummary {
  const totalDurationSeconds = segments.reduce(
    (sum, seg) => sum + seg.durationSeconds,
    0
  );
  const totalGpsPoints = segments.reduce((sum, seg) => sum + seg.pointCount, 0);

  // Calculate durations by segment type
  let matchedDuration = 0;
  let travelDuration = 0;
  let unmatchedDuration = 0;

  // Track duration by location type and individual locations
  const locationTypeMap = new Map<
    LocationType,
    { duration: number; locations: Map<string, { name: string; duration: number }> }
  >();

  for (const segment of segments) {
    switch (segment.segmentType) {
      case 'matched':
        matchedDuration += segment.durationSeconds;
        if (segment.locationType && segment.locationId && segment.locationName) {
          let typeData = locationTypeMap.get(segment.locationType);
          if (!typeData) {
            typeData = { duration: 0, locations: new Map() };
            locationTypeMap.set(segment.locationType, typeData);
          }
          typeData.duration += segment.durationSeconds;

          const existing = typeData.locations.get(segment.locationId);
          if (existing) {
            existing.duration += segment.durationSeconds;
          } else {
            typeData.locations.set(segment.locationId, {
              name: segment.locationName,
              duration: segment.durationSeconds,
            });
          }
        }
        break;
      case 'travel':
        travelDuration += segment.durationSeconds;
        break;
      case 'unmatched':
        unmatchedDuration += segment.durationSeconds;
        break;
    }
  }

  const safeDivide = (num: number, denom: number) =>
    denom > 0 ? (num / denom) * 100 : 0;

  // Build location type summaries
  const byLocationType: LocationTypeSummary[] = [];
  for (const [locationType, data] of locationTypeMap) {
    const locations: LocationDurationSummary[] = [];
    for (const [locationId, locData] of data.locations) {
      locations.push({
        locationId,
        locationName: locData.name,
        durationSeconds: locData.duration,
      });
    }
    // Sort locations by duration descending
    locations.sort((a, b) => b.durationSeconds - a.durationSeconds);

    byLocationType.push({
      locationType,
      durationSeconds: data.duration,
      percentage: safeDivide(data.duration, totalDurationSeconds),
      locations,
    });
  }
  // Sort by duration descending
  byLocationType.sort((a, b) => b.durationSeconds - a.durationSeconds);

  return {
    shiftId,
    totalDurationSeconds,
    totalGpsPoints,
    matchedDurationSeconds: matchedDuration,
    matchedPercentage: safeDivide(matchedDuration, totalDurationSeconds),
    travelDurationSeconds: travelDuration,
    travelPercentage: safeDivide(travelDuration, totalDurationSeconds),
    unmatchedDurationSeconds: unmatchedDuration,
    unmatchedPercentage: safeDivide(unmatchedDuration, totalDurationSeconds),
    byLocationType,
  };
}
