import { supabaseClient } from '@/lib/supabase/client';
import type { PayrollReportRow } from '@/types/payroll';

export async function getPayrollPeriodReport(
  periodStart: string,
  periodEnd: string,
  employeeIds?: string[]
): Promise<PayrollReportRow[]> {
  const { data, error } = await supabaseClient.rpc('get_payroll_period_report', {
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_employee_ids: employeeIds || null,
  });
  if (error) throw error;
  return (data as PayrollReportRow[]) || [];
}

export async function approvePayroll(
  employeeId: string,
  periodStart: string,
  periodEnd: string,
  notes?: string
) {
  const { data, error } = await supabaseClient.rpc('approve_payroll', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function unlockPayroll(
  employeeId: string,
  periodStart: string,
  periodEnd: string
) {
  const { data, error } = await supabaseClient.rpc('unlock_payroll', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}
