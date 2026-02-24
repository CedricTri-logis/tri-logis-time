// Historical GPS Visualization Types
// Types for the GPS history visualization feature (Spec 012)

/**
 * GPS Trail point for visualization
 * Matches RPC return structure from get_historical_shift_trail
 */
export interface HistoricalGpsPoint {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number | null;
  capturedAt: Date;
}

/**
 * Raw RPC row from get_historical_shift_trail
 */
export interface HistoricalGpsPointRow {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number | null;
  captured_at: string;
}

/**
 * Shift summary for history list view
 * Matches RPC return structure from get_employee_shift_history
 */
export interface ShiftHistorySummary {
  id: string;
  employeeId: string;
  employeeName: string;
  employeeEmail: string;
  clockedInAt: Date;
  clockedOutAt: Date;
  durationMinutes: number;
  gpsPointCount: number;
  totalDistanceKm: number | null;
  clockInLatitude: number | null;
  clockInLongitude: number | null;
  clockOutLatitude: number | null;
  clockOutLongitude: number | null;
}

/**
 * Raw RPC row from get_employee_shift_history
 */
export interface ShiftHistorySummaryRow {
  id: string;
  employee_id: string;
  employee_name: string;
  employee_email: string;
  clocked_in_at: string;
  clocked_out_at: string;
  duration_minutes: number;
  gps_point_count: number;
  total_distance_km: number | null;
  clock_in_latitude: number | null;
  clock_in_longitude: number | null;
  clock_out_latitude: number | null;
  clock_out_longitude: number | null;
}

/**
 * Multi-shift GPS point with shift identification
 * Matches RPC return structure from get_multi_shift_trails
 */
export interface MultiShiftGpsPoint extends HistoricalGpsPoint {
  shiftId: string;
  shiftDate: string; // Date only (YYYY-MM-DD)
}

/**
 * Raw RPC row from get_multi_shift_trails
 */
export interface MultiShiftGpsPointRow {
  id: string;
  shift_id: string;
  shift_date: string;
  latitude: number;
  longitude: number;
  accuracy: number | null;
  captured_at: string;
}

/**
 * Supervised employee for dropdown
 */
export interface SupervisedEmployee {
  id: string;
  fullName: string | null;
  email: string;
  employeeId: string | null;
}

/**
 * Raw RPC row from get_supervised_employees
 */
export interface SupervisedEmployeeRow {
  id: string;
  full_name: string | null;
  email: string;
  employee_id: string | null;
}

/**
 * Playback control state
 */
export interface PlaybackState {
  isPlaying: boolean;
  currentIndex: number;
  speedMultiplier: PlaybackSpeed;
  elapsedMs: number;
  totalDurationMs: number;
}

export type PlaybackSpeed = 0.5 | 1 | 2 | 4;

export const PLAYBACK_SPEEDS: { value: PlaybackSpeed; label: string }[] = [
  { value: 0.5, label: '0.5x (Slow)' },
  { value: 1, label: '1x (Normal)' },
  { value: 2, label: '2x (Fast)' },
  { value: 4, label: '4x (Very Fast)' },
];

/**
 * Export configuration options
 */
export interface GpsExportOptions {
  format: 'csv' | 'geojson';
  includeMetadata: boolean;
  dateRange?: {
    start: string;
    end: string;
  };
}

/**
 * Export metadata included in files
 */
export interface GpsExportMetadata {
  employeeName: string;
  employeeId: string;
  dateRange: string;
  totalDistanceKm: number;
  totalPoints: number;
  generatedAt: string;
}

/**
 * Multi-shift view configuration
 */
export interface MultiShiftViewConfig {
  employeeId: string;
  startDate: string; // YYYY-MM-DD
  endDate: string; // YYYY-MM-DD
  selectedShiftIds: string[];
}

/**
 * Trail rendering configuration
 */
export interface TrailRenderConfig {
  simplified: boolean;
  simplificationEpsilon: number;
  showAccuracyCircles: boolean;
  showTimestamps: boolean;
}

/**
 * Color assignment for multi-shift trails
 */
export interface ShiftColorMapping {
  shiftId: string;
  shiftDate: string;
  color: string; // HSL color string
}

/**
 * Transform RPC row to frontend type
 */
export function transformHistoricalGpsPointRow(
  row: HistoricalGpsPointRow
): HistoricalGpsPoint {
  return {
    id: row.id,
    latitude: row.latitude,
    longitude: row.longitude,
    accuracy: row.accuracy,
    capturedAt: new Date(row.captured_at),
  };
}

/**
 * Transform RPC row to frontend type
 */
export function transformShiftHistorySummaryRow(
  row: ShiftHistorySummaryRow
): ShiftHistorySummary {
  return {
    id: row.id,
    employeeId: row.employee_id,
    employeeName: row.employee_name,
    employeeEmail: row.employee_email,
    clockedInAt: new Date(row.clocked_in_at),
    clockedOutAt: new Date(row.clocked_out_at),
    durationMinutes: row.duration_minutes,
    gpsPointCount: row.gps_point_count,
    totalDistanceKm: row.total_distance_km,
    clockInLatitude: row.clock_in_latitude,
    clockInLongitude: row.clock_in_longitude,
    clockOutLatitude: row.clock_out_latitude,
    clockOutLongitude: row.clock_out_longitude,
  };
}

/**
 * Transform RPC row to frontend type
 */
export function transformMultiShiftGpsPointRow(
  row: MultiShiftGpsPointRow
): MultiShiftGpsPoint {
  return {
    id: row.id,
    shiftId: row.shift_id,
    shiftDate: row.shift_date,
    latitude: row.latitude,
    longitude: row.longitude,
    accuracy: row.accuracy,
    capturedAt: new Date(row.captured_at),
  };
}

/**
 * Transform RPC row to frontend type
 */
export function transformSupervisedEmployeeRow(
  row: SupervisedEmployeeRow
): SupervisedEmployee {
  return {
    id: row.id,
    fullName: row.full_name,
    email: row.email,
    employeeId: row.employee_id,
  };
}
