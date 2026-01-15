// Organization Dashboard Summary
// Returned by get_org_dashboard_summary() RPC function
export interface OrganizationDashboardSummary {
  employee_counts: {
    total: number;
    by_role: {
      employee?: number;
      manager?: number;
      admin?: number;
      super_admin?: number;
    };
    active_status: {
      active?: number;
      inactive?: number;
      suspended?: number;
    };
  };
  shift_stats: {
    active_shifts: number;
    completed_today: number;
    total_hours_today: number;
    total_hours_this_week: number;
    total_hours_this_month: number;
  };
  generated_at: string;
}

// Active Employee
// Returned in the activity feed from get_team_active_status()
export interface ActiveEmployee {
  employee_id: string;
  display_name: string;
  email: string;
  employee_number: string | null;
  is_active: boolean;
  current_shift_started_at: string | null;
  today_hours_seconds: number;
  monthly_hours_seconds: number;
  monthly_shift_count: number;
}

// Team Summary
// Returned by get_manager_team_summaries() for team comparison
export interface TeamSummary {
  manager_id: string;
  manager_name: string;
  manager_email: string;
  team_size: number;
  active_employees: number;
  total_hours: number;
  total_shifts: number;
  avg_hours_per_employee: number;
}

// Date Range for filtering queries
export type DateRangePreset = 'today' | 'this_week' | 'this_month' | 'custom';

export interface DateRange {
  preset: DateRangePreset;
  start_date?: string;
  end_date?: string;
}

// User identity from auth provider
export interface UserIdentity {
  id: string;
  email: string;
  name: string;
  role: string;
}

// Data freshness state
export type FreshnessState = 'fresh' | 'stale' | 'very_stale' | 'error';

export interface DataFreshnessInfo {
  state: FreshnessState;
  lastUpdated: Date | null;
  error?: Error;
}

// Utility functions for date ranges
export function getDateRangeDates(range: DateRange): { start: Date; end: Date } {
  const now = new Date();
  const end = new Date(now);
  let start: Date;

  switch (range.preset) {
    case 'today':
      start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      break;
    case 'this_week':
      const dayOfWeek = now.getDay();
      const diff = now.getDate() - dayOfWeek + (dayOfWeek === 0 ? -6 : 1);
      start = new Date(now.getFullYear(), now.getMonth(), diff);
      break;
    case 'this_month':
      start = new Date(now.getFullYear(), now.getMonth(), 1);
      break;
    case 'custom':
      start = range.start_date ? new Date(range.start_date) : new Date(now.getFullYear(), now.getMonth(), 1);
      if (range.end_date) {
        return { start, end: new Date(range.end_date) };
      }
      break;
    default:
      start = new Date(now.getFullYear(), now.getMonth(), 1);
  }

  return { start, end };
}

// Format seconds to hours and minutes
export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${hours}h ${minutes}m`;
}

// Format hours with one decimal
export function formatHours(hours: number): string {
  return hours.toFixed(1);
}
