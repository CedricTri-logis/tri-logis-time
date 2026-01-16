// Shift Monitoring Types
// Types for the supervisor shift monitoring feature

// Shift status for monitored employees
export type ShiftStatus = 'on-shift' | 'off-shift';

// GPS staleness levels (time since last update)
export type StalenessLevel = 'fresh' | 'stale' | 'very-stale' | 'unknown';

// Location point with metadata
export interface LocationPoint {
  latitude: number;
  longitude: number;
  accuracy: number;
  capturedAt: Date;
  isStale: boolean;
}

// Active shift information
export interface ActiveShift {
  id: string;
  clockedInAt: Date;
  clockInLocation: {
    latitude: number;
    longitude: number;
  } | null;
  clockInAccuracy: number | null;
}

// Monitored employee with current status
export interface MonitoredEmployee {
  id: string;
  fullName: string;
  employeeId: string | null;
  shiftStatus: ShiftStatus;
  currentShift: ActiveShift | null;
  currentLocation: LocationPoint | null;
}

// GPS trail point for path rendering
export interface GpsTrailPoint {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number;
  capturedAt: Date;
}

// Full shift detail for detail view
export interface ShiftDetail {
  id: string;
  employeeId: string;
  employeeName: string;
  status: 'active' | 'completed';
  clockedInAt: Date;
  clockedOutAt: Date | null;
  clockInLocation: {
    latitude: number;
    longitude: number;
  } | null;
  clockInAccuracy: number | null;
  clockOutLocation: {
    latitude: number;
    longitude: number;
  } | null;
  clockOutAccuracy: number | null;
  gpsPointCount: number;
}

// Current shift info for employee detail page
export interface EmployeeCurrentShift {
  shiftId: string;
  clockedInAt: Date;
  clockInLocation: {
    latitude: number;
    longitude: number;
  } | null;
  clockInAccuracy: number | null;
  gpsPointCount: number;
  latestLocation: LocationPoint | null;
}

// Supabase Realtime payload types
export interface ShiftRealtimePayload {
  commit_timestamp: string;
  eventType: 'INSERT' | 'UPDATE' | 'DELETE';
  new: {
    id: string;
    employee_id: string;
    status: 'active' | 'completed';
    clocked_in_at: string;
    clocked_out_at: string | null;
    clock_in_location: { latitude: number; longitude: number } | null;
    clock_in_accuracy: number | null;
    clock_out_location: { latitude: number; longitude: number } | null;
    clock_out_accuracy: number | null;
  } | null;
  old: {
    id: string;
    employee_id: string;
    status: 'active' | 'completed';
  } | null;
  errors: string[] | null;
}

export interface GpsPointRealtimePayload {
  commit_timestamp: string;
  eventType: 'INSERT';
  new: {
    id: string;
    client_id: string;
    shift_id: string;
    employee_id: string;
    latitude: number;
    longitude: number;
    accuracy: number;
    captured_at: string;
    received_at: string;
    device_id: string | null;
  };
  old: null;
  errors: string[] | null;
}

// Raw RPC response types (from database)
export interface MonitoredTeamRow {
  id: string;
  full_name: string;
  employee_id: string | null;
  shift_status: 'on-shift' | 'off-shift';
  current_shift_id: string | null;
  clocked_in_at: string | null;
  clock_in_latitude: number | null;
  clock_in_longitude: number | null;
  latest_latitude: number | null;
  latest_longitude: number | null;
  latest_accuracy: number | null;
  latest_captured_at: string | null;
}

export interface ShiftDetailRow {
  id: string;
  employee_id: string;
  employee_name: string;
  status: 'active' | 'completed';
  clocked_in_at: string;
  clocked_out_at: string | null;
  clock_in_latitude: number | null;
  clock_in_longitude: number | null;
  clock_in_accuracy: number | null;
  clock_out_latitude: number | null;
  clock_out_longitude: number | null;
  clock_out_accuracy: number | null;
  gps_point_count: number;
}

export interface GpsTrailRow {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number;
  captured_at: string;
}

export interface EmployeeCurrentShiftRow {
  shift_id: string;
  clocked_in_at: string;
  clock_in_latitude: number | null;
  clock_in_longitude: number | null;
  clock_in_accuracy: number | null;
  gps_point_count: number;
  latest_latitude: number | null;
  latest_longitude: number | null;
  latest_accuracy: number | null;
  latest_captured_at: string | null;
}

// Connection status for realtime subscriptions
export type ConnectionStatus = 'connecting' | 'connected' | 'disconnected' | 'error';

// Filter state for team list
export interface MonitoringFilters {
  search: string;
  shiftStatus: 'all' | 'on-shift' | 'off-shift';
}

// Utility functions for staleness calculation
export const STALENESS_THRESHOLDS = {
  FRESH_MAX_MINUTES: 5,
  STALE_MAX_MINUTES: 15,
} as const;

export function getStalenessLevel(capturedAt: Date | null): StalenessLevel {
  if (!capturedAt) return 'unknown';

  const now = new Date();
  const ageMs = now.getTime() - capturedAt.getTime();
  const ageMinutes = ageMs / (1000 * 60);

  if (ageMinutes <= STALENESS_THRESHOLDS.FRESH_MAX_MINUTES) return 'fresh';
  if (ageMinutes <= STALENESS_THRESHOLDS.STALE_MAX_MINUTES) return 'stale';
  return 'very-stale';
}

// Transform RPC row to frontend type
export function transformMonitoredTeamRow(row: MonitoredTeamRow): MonitoredEmployee {
  const currentLocation: LocationPoint | null =
    row.latest_latitude !== null && row.latest_longitude !== null && row.latest_captured_at
      ? {
          latitude: row.latest_latitude,
          longitude: row.latest_longitude,
          accuracy: row.latest_accuracy ?? 0,
          capturedAt: new Date(row.latest_captured_at),
          isStale: getStalenessLevel(new Date(row.latest_captured_at)) !== 'fresh',
        }
      : null;

  const currentShift: ActiveShift | null =
    row.current_shift_id && row.clocked_in_at
      ? {
          id: row.current_shift_id,
          clockedInAt: new Date(row.clocked_in_at),
          clockInLocation:
            row.clock_in_latitude !== null && row.clock_in_longitude !== null
              ? { latitude: row.clock_in_latitude, longitude: row.clock_in_longitude }
              : null,
          clockInAccuracy: null, // Not returned by get_monitored_team
        }
      : null;

  return {
    id: row.id,
    fullName: row.full_name,
    employeeId: row.employee_id,
    shiftStatus: row.shift_status,
    currentShift,
    currentLocation,
  };
}

export function transformGpsTrailRow(row: GpsTrailRow): GpsTrailPoint {
  return {
    id: row.id,
    latitude: row.latitude,
    longitude: row.longitude,
    accuracy: row.accuracy,
    capturedAt: new Date(row.captured_at),
  };
}

// Format duration as HH:MM:SS for live counter
export function formatDurationHMS(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  return [
    hours.toString().padStart(2, '0'),
    minutes.toString().padStart(2, '0'),
    secs.toString().padStart(2, '0'),
  ].join(':');
}

// Format duration as Xh Ym for display
export function formatDurationHM(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  if (hours === 0) {
    return `${minutes}m`;
  }
  return `${hours}h ${minutes}m`;
}
