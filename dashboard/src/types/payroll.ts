export interface PayrollReportRow {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  pay_type: 'hourly' | 'annual';
  primary_category: string | null;
  secondary_categories: string[] | null;
  date: string; // YYYY-MM-DD
  approved_minutes: number;
  break_minutes: number;
  callback_worked_minutes: number;
  callback_billed_minutes: number;
  callback_bonus_minutes: number;
  cleaning_minutes: number;
  maintenance_minutes: number;
  admin_minutes: number;
  uncovered_minutes: number;
  hourly_rate: number | null;
  annual_salary: number | null;
  period_salary: number | null;
  base_amount: number;
  weekend_cleaning_minutes: number;
  weekend_premium_rate: number;
  premium_amount: number;
  callback_bonus_amount: number | null;
  total_amount: number;
  day_approval_status: 'approved' | 'pending' | 'no_shift';
  payroll_status: 'approved' | 'pending';
  payroll_approved_by: string | null;
  payroll_approved_at: string | null;
  reimbursable_km?: number | null;
  reimbursement_amount?: number | null;
  break_deduction_minutes: number;
  break_deduction_waived: boolean;
  rejected_minutes: number;
  // Hour bank
  bank_deposit_hours: number | null;
  bank_deposit_amount: number | null;
  bank_withdrawal_hours: number | null;
  bank_withdrawal_amount: number | null;
  bank_balance_dollars: number | null;
  bank_balance_hours: number | null;
  // Sick leave
  sick_leave_hours: number | null;
  sick_leave_amount: number | null;
  sick_leave_remaining: number | null;
}

export interface PayrollEmployeeSummary {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  pay_type: 'hourly' | 'annual';
  primary_category: string | null;
  secondary_categories: string[] | null;
  total_approved_minutes: number;
  total_break_minutes: number;
  total_callback_bonus_minutes: number;
  days_without_break: number;
  total_break_deduction_minutes: number;
  total_rejected_minutes: number;
  hourly_rate: number | null;
  hourly_rate_display: string;
  annual_salary: number | null;
  work_session_coverage_pct: number;
  total_premium: number;
  total_base: number;
  total_amount: number;
  total_callback_bonus_amount: number;
  days_approved: number;
  days_worked: number;
  payroll_status: 'approved' | 'pending';
  payroll_approved_by: string | null;
  payroll_approved_at: string | null;
  // Hour bank (period totals)
  bank_deposit_hours: number;
  bank_deposit_amount: number;
  bank_withdrawal_hours: number;
  bank_withdrawal_amount: number;
  bank_net_amount: number;
  bank_balance_dollars: number;
  bank_balance_hours: number;
  // Sick leave (period totals)
  sick_leave_hours: number;
  sick_leave_amount: number;
  sick_leave_remaining: number;
  days: PayrollReportRow[];
}

export interface PayrollCategoryGroup {
  category: string;
  employees: PayrollEmployeeSummary[];
  totals: {
    approved_minutes: number;
    base_amount: number;
    premium_amount: number;
    total_amount: number;
    break_deduction_minutes: number;
    rejected_minutes: number;
    callback_bonus_minutes: number;
    bank_net_amount: number;
    sick_leave_amount: number;
  };
}

export interface HourBankTransaction {
  transaction_id: string;
  created_at: string;
  type: 'deposit' | 'withdrawal' | 'sick_leave';
  hours: number;
  hourly_rate: number;
  amount: number;
  period_start: string;
  period_end: string;
  reason: string;
  created_by_name: string;
  can_delete: boolean;
}

export interface PayPeriod {
  start: string; // YYYY-MM-DD
  end: string;   // YYYY-MM-DD
}
