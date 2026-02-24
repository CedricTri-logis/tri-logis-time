/**
 * Report Types and Interfaces
 * Spec: 013-reports-export
 */

// Report type enum
export type ReportType = 'timesheet' | 'activity_summary' | 'attendance' | 'shift_history';

// Report format options
export type ReportFormat = 'pdf' | 'csv';

// Report job status
export type ReportJobStatus = 'pending' | 'processing' | 'completed' | 'failed';

// Schedule frequency options
export type ScheduleFrequency = 'weekly' | 'bi_weekly' | 'monthly';

// Schedule status
export type ScheduleStatus = 'active' | 'paused' | 'deleted';

// Date range presets
export type DateRangePreset = 'this_week' | 'last_week' | 'this_month' | 'last_month';

/**
 * Date range configuration for reports
 */
export interface ReportDateRange {
  preset?: DateRangePreset;
  start?: string; // ISO date format: YYYY-MM-DD
  end?: string; // ISO date format: YYYY-MM-DD
}

/**
 * Report configuration options
 */
export interface ReportOptions {
  include_incomplete_shifts?: boolean;
  include_gps_summary?: boolean;
  group_by?: 'employee' | 'date';
}

/**
 * Full report configuration object
 */
export interface ReportConfig {
  date_range: ReportDateRange;
  employee_filter: 'all' | string | string[]; // 'all', 'team:{id}', 'employee:{id}', or array of UUIDs
  format: ReportFormat;
  options?: ReportOptions;
}

/**
 * Report job record from database
 */
export interface ReportJob {
  id: string;
  user_id: string;
  report_type: ReportType;
  status: ReportJobStatus;
  config: ReportConfig;
  started_at?: string;
  completed_at?: string;
  error_message?: string;
  file_path?: string;
  file_size_bytes?: number;
  record_count?: number;
  is_async: boolean;
  schedule_id?: string;
  created_at: string;
  expires_at: string;
}

/**
 * Schedule configuration for day/time
 */
export interface ScheduleConfig {
  day_of_week?: 0 | 1 | 2 | 3 | 4 | 5 | 6; // 0 = Sunday
  day_of_month?: number; // 1-28
  time: string; // HH:MM format
  week_parity?: 'odd' | 'even'; // For bi-weekly
  timezone: string; // IANA timezone
}

/**
 * Report schedule record from database
 */
export interface ReportSchedule {
  id: string;
  user_id: string;
  name: string;
  report_type: ReportType;
  config: ReportConfig;
  frequency: ScheduleFrequency;
  schedule_config: ScheduleConfig;
  status: ScheduleStatus;
  next_run_at: string;
  last_run_at?: string;
  last_run_status?: 'success' | 'failed';
  run_count: number;
  failure_count: number;
  created_at: string;
  updated_at: string;
}

/**
 * Audit log entry
 */
export interface ReportAuditLog {
  id: string;
  job_id?: string;
  user_id: string;
  action: 'generated' | 'downloaded' | 'deleted' | 'scheduled';
  report_type: ReportType;
  parameters: ReportConfig;
  status: 'success' | 'failed';
  error_message?: string;
  file_path?: string;
  ip_address?: string;
  user_agent?: string;
  created_at: string;
}

// ----- RPC Response Types -----

/**
 * Response from generate_report RPC
 */
export interface GenerateReportResponse {
  job_id: string;
  status: ReportJobStatus;
  download_url?: string;
  is_async?: boolean;
  estimated_duration_seconds?: number;
  expires_at?: string;
}

/**
 * Response from get_report_job_status RPC
 */
export interface ReportJobStatusResponse {
  job_id: string;
  status: ReportJobStatus;
  started_at?: string;
  completed_at?: string;
  failed_at?: string;
  progress_percent?: number;
  download_url?: string;
  file_path?: string;
  file_size_bytes?: number;
  record_count?: number;
  expires_at?: string;
  error_message?: string;
}

/**
 * Response from get_report_history RPC
 */
export interface ReportHistoryResponse {
  items: ReportHistoryItem[];
  total_count: number;
  has_more: boolean;
}

/**
 * Single item in report history list
 */
export interface ReportHistoryItem {
  job_id: string;
  report_type: ReportType;
  status: ReportJobStatus;
  config: ReportConfig;
  file_path?: string;
  file_size_bytes?: number;
  record_count?: number;
  created_at: string;
  expires_at: string;
  download_available: boolean;
}

/**
 * Response from count_report_records RPC
 */
export interface RecordCountResponse {
  count: number;
}

// ----- Timesheet Report Types -----

/**
 * Timesheet report data row
 */
export interface TimesheetReportRow {
  employee_id: string;
  employee_name: string;
  employee_identifier: string;
  shift_date: string;
  clocked_in_at: string;
  clocked_out_at?: string;
  duration_minutes: number;
  status: 'complete' | 'incomplete';
  notes?: string;
}

/**
 * Timesheet report summary
 */
export interface TimesheetSummary {
  total_employees: number;
  total_shifts: number;
  total_hours: number;
  incomplete_shifts: number;
  date_range: string;
}

// ----- Activity Summary Types -----

/**
 * Activity summary report data
 */
export interface ActivitySummaryData {
  period: string;
  total_hours: number;
  total_shifts: number;
  avg_hours_per_employee: number;
  employees_active: number;
  hours_by_day: Record<string, number>;
}

// ----- Attendance Report Types -----

/**
 * Attendance report data row
 */
export interface AttendanceReportRow {
  employee_id: string;
  employee_name: string;
  total_working_days: number;
  days_worked: number;
  days_absent: number;
  attendance_rate: number;
  calendar_data: Record<string, boolean>; // date -> worked
}

// ----- Shift History Export Types -----

/**
 * Shift history export row
 */
export interface ShiftHistoryExportRow {
  employee_id: string;
  employee_name: string;
  employee_identifier: string;
  shift_id: string;
  clocked_in_at: string;
  clocked_out_at?: string;
  duration_minutes: number;
  status: string;
  gps_point_count: number;
  total_distance_km?: number;
  clock_in_latitude?: number;
  clock_in_longitude?: number;
  clock_out_latitude?: number;
  clock_out_longitude?: number;
}

// ----- Schedule Types -----

/**
 * Response from get_report_schedules RPC
 */
export interface ReportSchedulesResponse {
  items: ReportSchedule[];
  total_count: number;
}

/**
 * Response from create_report_schedule RPC
 */
export interface CreateScheduleResponse {
  schedule_id: string;
  name: string;
  next_run_at: string;
  status: ScheduleStatus;
}

/**
 * Response from update_report_schedule RPC
 */
export interface UpdateScheduleResponse {
  id: string;
  status: ScheduleStatus;
  updated_at: string;
}

// ----- Notification Types -----

/**
 * Pending notification item
 */
export interface PendingNotification {
  job_id: string;
  report_type: ReportType;
  completed_at: string;
  schedule_name?: string;
}

/**
 * Response from get_pending_report_notifications RPC
 */
export interface PendingNotificationsResponse {
  count: number;
  items: PendingNotification[];
}

// ----- UI State Types -----

/**
 * Report generation state for UI
 */
export type ReportGenerationState = 'idle' | 'counting' | 'generating' | 'polling' | 'completed' | 'failed';

/**
 * Report card type for landing page
 */
export interface ReportTypeCard {
  type: ReportType;
  title: string;
  description: string;
  icon: string;
  href: string;
}

/**
 * Employee option for selector
 */
export interface EmployeeOption {
  id: string;
  full_name: string;
  employee_id?: string;
}

/**
 * Report type display information
 */
export const REPORT_TYPE_INFO: Record<ReportType, { label: string; description: string }> = {
  timesheet: {
    label: 'Timesheet Report',
    description: 'Comprehensive shift records with hours worked',
  },
  activity_summary: {
    label: 'Team Activity Summary',
    description: 'Aggregate metrics and trends for teams',
  },
  attendance: {
    label: 'Attendance Report',
    description: 'Employee attendance and absence records',
  },
  shift_history: {
    label: 'Shift History Export',
    description: 'Detailed shift data with GPS information',
  },
};

/**
 * Format display information
 */
export const FORMAT_INFO: Record<ReportFormat, { label: string; description: string }> = {
  pdf: {
    label: 'PDF',
    description: 'Formatted document for printing',
  },
  csv: {
    label: 'CSV',
    description: 'Spreadsheet format for Excel/Sheets',
  },
};

/**
 * Frequency display information
 */
export const FREQUENCY_INFO: Record<ScheduleFrequency, { label: string; description: string }> = {
  weekly: {
    label: 'Weekly',
    description: 'Every week on the selected day',
  },
  bi_weekly: {
    label: 'Bi-weekly',
    description: 'Every two weeks',
  },
  monthly: {
    label: 'Monthly',
    description: 'Once per month on the selected day',
  },
};
