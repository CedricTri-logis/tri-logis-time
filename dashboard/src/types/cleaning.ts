// Cleaning Session Tracking Types (Spec 016)

export type CleaningSessionStatus = 'in_progress' | 'completed' | 'auto_closed' | 'manually_closed';
export type StudioType = 'unit' | 'common_area' | 'conciergerie';

/**
 * Cleaning session row from RPC (snake_case)
 */
export interface CleaningSessionRow {
  id: string;
  employee_id: string;
  employee_name: string;
  studio_id: string;
  studio_number: string;
  building_name: string;
  studio_type: StudioType;
  shift_id: string;
  status: CleaningSessionStatus;
  started_at: string;
  completed_at: string | null;
  duration_minutes: number | null;
  is_flagged: boolean;
  flag_reason: string | null;
}

/**
 * Frontend cleaning session (camelCase)
 */
export interface CleaningSession {
  id: string;
  employeeId: string;
  employeeName: string;
  studioId: string;
  studioNumber: string;
  buildingName: string;
  studioType: StudioType;
  shiftId: string;
  status: CleaningSessionStatus;
  startedAt: Date;
  completedAt: Date | null;
  durationMinutes: number | null;
  isFlagged: boolean;
  flagReason: string | null;
}

/**
 * Summary statistics from get_cleaning_dashboard RPC
 */
export interface CleaningSummary {
  totalSessions: number;
  completed: number;
  inProgress: number;
  autoClosed: number;
  avgDurationMinutes: number;
  flaggedCount: number;
}

/**
 * Per-building cleaning stats
 */
export interface BuildingStats {
  buildingId: string;
  buildingName: string;
  totalStudios: number;
  cleanedToday: number;
  inProgress: number;
  notStarted: number;
  avgDurationMinutes: number;
}

/**
 * Per-employee cleaning performance
 */
export interface EmployeeCleaningStats {
  employeeName: string;
  totalSessions: number;
  avgDurationMinutes: number;
  sessionsByBuilding: { buildingName: string; count: number; avgDuration: number }[];
  flaggedSessions: number;
}

// Display helpers

export const CLEANING_STATUS_LABELS: Record<CleaningSessionStatus, string> = {
  in_progress: 'In Progress',
  completed: 'Completed',
  auto_closed: 'Auto-Closed',
  manually_closed: 'Manually Closed',
};

export const CLEANING_STATUS_COLORS: Record<CleaningSessionStatus, string> = {
  in_progress: 'blue',
  completed: 'green',
  auto_closed: 'orange',
  manually_closed: 'yellow',
};

export const STUDIO_TYPE_LABELS: Record<StudioType, string> = {
  unit: 'Unit',
  common_area: 'Common Area',
  conciergerie: 'Conciergerie',
};

/**
 * Transform RPC row to frontend type
 */
export function transformCleaningSessionRow(row: CleaningSessionRow): CleaningSession {
  return {
    id: row.id,
    employeeId: row.employee_id,
    employeeName: row.employee_name,
    studioId: row.studio_id,
    studioNumber: row.studio_number,
    buildingName: row.building_name,
    studioType: row.studio_type,
    shiftId: row.shift_id,
    status: row.status,
    startedAt: new Date(row.started_at),
    completedAt: row.completed_at ? new Date(row.completed_at) : null,
    durationMinutes: row.duration_minutes,
    isFlagged: row.is_flagged,
    flagReason: row.flag_reason,
  };
}

/**
 * Format duration in minutes to display string
 */
export function formatDuration(minutes: number | null): string {
  if (minutes == null) return '—';
  const h = Math.floor(minutes / 60);
  const m = Math.round(minutes % 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}
