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
import { toLocalDateString, addDays, getMonday } from '@/lib/utils/date-utils';

export function getDateRangeDates(range: DateRange): { start: string; end: string } {
  const today = toLocalDateString(new Date());

  switch (range.preset) {
    case 'today':
      return { start: today, end: today };
    case 'this_week':
      return { start: getMonday(today), end: addDays(getMonday(today), 6) };
    case 'this_month': {
      const now = new Date();
      const firstOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);
      const lastOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0);
      return { start: toLocalDateString(firstOfMonth), end: toLocalDateString(lastOfMonth) };
    }
    case 'custom':
      return {
        start: range.start_date ?? toLocalDateString(new Date(new Date().getFullYear(), new Date().getMonth(), 1)),
        end: range.end_date ?? today,
      };
    default: {
      const now = new Date();
      return { start: toLocalDateString(new Date(now.getFullYear(), now.getMonth(), 1)), end: today };
    }
  }
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
