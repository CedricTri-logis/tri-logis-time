// Work Session Types (unified cleaning/maintenance/admin)

export type ActivityType = 'cleaning' | 'maintenance' | 'admin';
export type WorkSessionStatus = 'in_progress' | 'completed' | 'auto_closed' | 'manually_closed';

/**
 * Work session row from RPC (snake_case, matches get_work_sessions_dashboard response)
 */
export interface WorkSessionRow {
  id: string;
  employee_id: string;
  employee_name: string;
  activity_type: ActivityType;
  location_type: string | null;
  studio_number: string | null;
  studio_type: string | null;
  building_name: string | null;
  unit_number: string | null;
  status: WorkSessionStatus;
  started_at: string;
  completed_at: string | null;
  duration_minutes: number | null;
  is_flagged: boolean;
  flag_reason: string | null;
  notes: string | null;
}

/**
 * Frontend work session (camelCase)
 */
export interface WorkSession {
  id: string;
  employeeId: string;
  employeeName: string;
  activityType: ActivityType;
  locationType: string | null;
  studioNumber: string | null;
  studioType: string | null;
  buildingName: string | null;
  unitNumber: string | null;
  status: WorkSessionStatus;
  startedAt: Date;
  completedAt: Date | null;
  durationMinutes: number | null;
  isFlagged: boolean;
  flagReason: string | null;
  notes: string | null;
}

/**
 * Summary statistics from get_work_sessions_dashboard RPC
 */
export interface WorkSessionSummary {
  totalSessions: number;
  completed: number;
  inProgress: number;
  autoClosed: number;
  manuallyClosed: number;
  avgDurationMinutes: number | null;
  flaggedCount: number;
  byType: {
    cleaning: number;
    maintenance: number;
    admin: number;
  };
}

/**
 * Full dashboard response from get_work_sessions_dashboard RPC (snake_case)
 */
export interface WorkSessionDashboardRpcResponse {
  summary: {
    total_sessions: number;
    completed: number;
    in_progress: number;
    auto_closed: number;
    manually_closed: number;
    avg_duration_minutes: number | null;
    flagged_count: number;
    by_type: {
      cleaning: number;
      maintenance: number;
      admin: number;
    };
  };
  sessions: WorkSessionRow[];
  total_count: number;
}

// Display helpers

export const ACTIVITY_TYPE_CONFIG: Record<ActivityType, {
  label: string;
  color: string;
  bgColor: string;
  icon: string;
}> = {
  cleaning: { label: 'Menage', color: '#4CAF50', bgColor: '#E8F5E9', icon: 'SprayCan' },
  maintenance: { label: 'Entretien', color: '#FF9800', bgColor: '#FFF3E0', icon: 'Wrench' },
  admin: { label: 'Administration', color: '#2196F3', bgColor: '#E3F2FD', icon: 'Briefcase' },
};

export const WORK_SESSION_STATUS_LABELS: Record<WorkSessionStatus, string> = {
  in_progress: 'In Progress',
  completed: 'Completed',
  auto_closed: 'Auto-Closed',
  manually_closed: 'Manually Closed',
};

export const WORK_SESSION_STATUS_COLORS: Record<WorkSessionStatus, string> = {
  in_progress: 'blue',
  completed: 'green',
  auto_closed: 'orange',
  manually_closed: 'yellow',
};

/**
 * Transform RPC row to frontend type
 */
export function transformWorkSessionRow(row: WorkSessionRow): WorkSession {
  return {
    id: row.id,
    employeeId: row.employee_id,
    employeeName: row.employee_name,
    activityType: row.activity_type,
    locationType: row.location_type,
    studioNumber: row.studio_number,
    studioType: row.studio_type,
    buildingName: row.building_name,
    unitNumber: row.unit_number,
    status: row.status,
    startedAt: new Date(row.started_at),
    completedAt: row.completed_at ? new Date(row.completed_at) : null,
    durationMinutes: row.duration_minutes,
    isFlagged: row.is_flagged,
    flagReason: row.flag_reason,
    notes: row.notes,
  };
}

/**
 * Format duration in minutes to display string
 */
export function formatWorkSessionDuration(minutes: number | null): string {
  if (minutes == null) return '\u2014';
  const h = Math.floor(minutes / 60);
  const m = Math.round(minutes % 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}
