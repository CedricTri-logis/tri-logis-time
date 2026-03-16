import { supabaseClient } from '@/lib/supabase/client';
import type {
  EmployeeHourlyRateWithCreator,
  EmployeeRateListItem,
  WeekendCleaningPremium,
  TimesheetWithPayRow,
} from '@/types/remuneration';

// ── Employee Hourly Rates ──

export async function getEmployeeRatesList(): Promise<EmployeeRateListItem[]> {
  // Get all employees with their current rate (if any)
  const { data, error } = await supabaseClient
    .from('employee_profiles')
    .select('id, full_name, employee_id')
    .eq('status', 'active')
    .order('full_name');

  if (error) throw error;

  // Get all active rates
  const { data: rates, error: ratesError } = await supabaseClient
    .from('employee_hourly_rates')
    .select('employee_id, rate, effective_from')
    .is('effective_to', null);

  if (ratesError) throw ratesError;

  const rateMap = new Map(
    (rates || []).map((r) => [r.employee_id, r])
  );

  return (data || []).map((emp) => {
    const rate = rateMap.get(emp.id);
    return {
      employee_id: emp.id,
      full_name: emp.full_name,
      employee_id_code: emp.employee_id,
      current_rate: rate?.rate ?? null,
      effective_from: rate?.effective_from ?? null,
    };
  });
}

export async function getEmployeeRateHistory(
  employeeId: string
): Promise<EmployeeHourlyRateWithCreator[]> {
  const { data, error } = await supabaseClient
    .from('employee_hourly_rates')
    .select(`
      *,
      creator:created_by(full_name)
    `)
    .eq('employee_id', employeeId)
    .order('effective_from', { ascending: false });

  if (error) throw error;

  return (data || []).map((row) => ({
    ...row,
    creator_name: (row.creator as any)?.full_name ?? null,
  }));
}

export async function upsertEmployeeRate(
  employeeId: string,
  rate: number,
  effectiveFrom: string
): Promise<void> {
  // Get current user for created_by
  const { data: { user } } = await supabaseClient.auth.getUser();

  // 1. Close current active rate (if any)
  const { data: activeRate } = await supabaseClient
    .from('employee_hourly_rates')
    .select('id')
    .eq('employee_id', employeeId)
    .is('effective_to', null)
    .single();

  if (activeRate) {
    // Close previous period: effective_to = day before new effective_from
    const closingDate = new Date(effectiveFrom);
    closingDate.setDate(closingDate.getDate() - 1);
    const closingDateStr = closingDate.toISOString().split('T')[0];

    const { error: updateError } = await supabaseClient
      .from('employee_hourly_rates')
      .update({ effective_to: closingDateStr })
      .eq('id', activeRate.id);

    if (updateError) throw updateError;
  }

  // 2. Insert new rate with created_by
  const { error: insertError } = await supabaseClient
    .from('employee_hourly_rates')
    .insert({
      employee_id: employeeId,
      rate,
      effective_from: effectiveFrom,
      effective_to: null,
      created_by: user?.id ?? null,
    });

  if (insertError) throw insertError;
}

// ── Rate Period Editing ──

interface RpcResult {
  success: boolean;
  error?: { code: string; message: string };
}

export async function updateRatePeriod(
  rateId: string,
  rate: number,
  effectiveFrom: string,
  effectiveTo: string | null
): Promise<RpcResult> {
  const { data, error } = await supabaseClient.rpc('update_employee_rate_period', {
    p_rate_id: rateId,
    p_rate: rate,
    p_effective_from: effectiveFrom,
    p_effective_to: effectiveTo,
  });

  if (error) throw error;
  return data as RpcResult;
}

export async function deleteRatePeriod(
  rateId: string
): Promise<RpcResult> {
  const { data, error } = await supabaseClient.rpc('delete_employee_rate_period', {
    p_rate_id: rateId,
  });

  if (error) throw error;
  return data as RpcResult;
}

// ── Pay Settings ──

export async function getWeekendPremium(): Promise<WeekendCleaningPremium> {
  const { data, error } = await supabaseClient
    .from('pay_settings')
    .select('value')
    .eq('key', 'weekend_cleaning_premium')
    .single();

  if (error) throw error;
  return data.value as WeekendCleaningPremium;
}

export async function updateWeekendPremium(amount: number): Promise<void> {
  const { error } = await supabaseClient
    .from('pay_settings')
    .update({
      value: { amount, currency: 'CAD' },
    })
    .eq('key', 'weekend_cleaning_premium');

  if (error) throw error;
}

// ── Timesheet with Pay ──

export async function getTimesheetWithPay(
  startDate: string,
  endDate: string,
  employeeIds?: string[]
): Promise<TimesheetWithPayRow[]> {
  const { data, error } = await supabaseClient.rpc('get_timesheet_with_pay', {
    p_start_date: startDate,
    p_end_date: endDate,
    p_employee_ids: employeeIds ?? null,
  });

  if (error) throw error;
  return data || [];
}
