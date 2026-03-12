// Types for employee hourly rates & pay settings

export interface EmployeeHourlyRate {
  id: string;
  employee_id: string;
  rate: number;
  effective_from: string; // DATE as ISO string
  effective_to: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface EmployeeHourlyRateWithCreator extends EmployeeHourlyRate {
  creator_name: string | null; // joined from employee_profiles
}

export interface EmployeeRateListItem {
  employee_id: string;
  full_name: string | null;
  employee_id_code: string | null;
  current_rate: number | null;
  effective_from: string | null;
}

export interface PaySetting {
  id: string;
  key: string;
  value: Record<string, unknown>;
  updated_at: string;
  updated_by: string | null;
}

export interface WeekendCleaningPremium {
  amount: number;
  currency: string;
}

export interface TimesheetWithPayRow {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  date: string;
  approved_minutes: number;
  hourly_rate: number | null;
  base_amount: number;
  weekend_cleaning_minutes: number;
  weekend_premium_rate: number;
  premium_amount: number;
  total_amount: number;
  has_rate: boolean;
}
