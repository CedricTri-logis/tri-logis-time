import { supabaseClient, workforceClient } from '@/lib/supabase/client';
import type {
  EmployeeHourlyRateWithCreator,
  EmployeeAnnualSalaryWithCreator,
  EmployeeRateListItem,
  WeekendCleaningPremium,
  TimesheetWithPayRow,
} from '@/types/remuneration';

// ── Employee Hourly Rates ──

export async function getEmployeeRatesList(): Promise<EmployeeRateListItem[]> {
  const { data, error } = await workforceClient()
    .from('employee_profiles')
    .select('id, full_name, employee_id, pay_type')
    .eq('status', 'active')
    .order('full_name');

  if (error) throw error;

  const { data: rates, error: ratesError } = await workforceClient()
    .from('employee_hourly_rates')
    .select('employee_id, rate, effective_from')
    .is('effective_to', null);

  if (ratesError) throw ratesError;

  const { data: salaries, error: salariesError } = await workforceClient()
    .from('employee_annual_salaries')
    .select('employee_id, salary, effective_from')
    .is('effective_to', null);

  if (salariesError) throw salariesError;

  const rateMap = new Map(
    (rates || []).map((r) => [r.employee_id, r])
  );
  const salaryMap = new Map(
    (salaries || []).map((s) => [s.employee_id, s])
  );

  return (data || []).map((emp) => {
    const rate = rateMap.get(emp.id);
    const salary = salaryMap.get(emp.id);
    const payType = (emp.pay_type as 'hourly' | 'annual') || 'hourly';
    return {
      employee_id: emp.id,
      full_name: emp.full_name,
      employee_id_code: emp.employee_id,
      pay_type: payType,
      current_rate: rate?.rate ?? null,
      current_salary: salary?.salary ?? null,
      effective_from: payType === 'annual'
        ? (salary?.effective_from ?? null)
        : (rate?.effective_from ?? null),
    };
  });
}

export async function getEmployeeRateHistory(
  employeeId: string
): Promise<EmployeeHourlyRateWithCreator[]> {
  const { data, error } = await workforceClient()
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
  const { data: { user } } = await supabaseClient.auth.getUser();

  const { data: activeRate } = await workforceClient()
    .from('employee_hourly_rates')
    .select('id')
    .eq('employee_id', employeeId)
    .is('effective_to', null)
    .single();

  if (activeRate) {
    const closingDate = new Date(effectiveFrom);
    closingDate.setDate(closingDate.getDate() - 1);
    const closingDateStr = closingDate.toISOString().split('T')[0];

    const { error: updateError } = await workforceClient()
      .from('employee_hourly_rates')
      .update({ effective_to: closingDateStr })
      .eq('id', activeRate.id);

    if (updateError) throw updateError;
  }

  const { error: insertError } = await workforceClient()
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

// ── Employee Annual Salaries ──

export async function getEmployeeSalaryHistory(
  employeeId: string
): Promise<EmployeeAnnualSalaryWithCreator[]> {
  const { data, error } = await workforceClient()
    .from('employee_annual_salaries')
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

export async function upsertEmployeeSalary(
  employeeId: string,
  salary: number,
  effectiveFrom: string
): Promise<void> {
  const { data: { user } } = await supabaseClient.auth.getUser();

  const { data: activeSalary } = await workforceClient()
    .from('employee_annual_salaries')
    .select('id')
    .eq('employee_id', employeeId)
    .is('effective_to', null)
    .single();

  if (activeSalary) {
    const closingDate = new Date(effectiveFrom);
    closingDate.setDate(closingDate.getDate() - 1);
    const closingDateStr = closingDate.toISOString().split('T')[0];

    const { error: updateError } = await workforceClient()
      .from('employee_annual_salaries')
      .update({ effective_to: closingDateStr })
      .eq('id', activeSalary.id);

    if (updateError) throw updateError;
  }

  const { error: insertError } = await workforceClient()
    .from('employee_annual_salaries')
    .insert({
      employee_id: employeeId,
      salary,
      effective_from: effectiveFrom,
      effective_to: null,
      created_by: user?.id ?? null,
    });

  if (insertError) throw insertError;
}

// ── Pay Type ──

export async function updateEmployeePayType(
  employeeId: string,
  payType: 'hourly' | 'annual'
): Promise<void> {
  const { error } = await workforceClient().rpc('update_employee_pay_type', {
    p_employee_id: employeeId,
    p_pay_type: payType,
  });

  if (error) throw error;
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
  const { data, error } = await workforceClient().rpc('update_employee_rate_period', {
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
  const { data, error } = await workforceClient().rpc('delete_employee_rate_period', {
    p_rate_id: rateId,
  });

  if (error) throw error;
  return data as RpcResult;
}

// ── Pay Settings ──

export async function getWeekendPremium(): Promise<WeekendCleaningPremium> {
  const { data, error } = await workforceClient()
    .from('pay_settings')
    .select('value')
    .eq('key', 'weekend_cleaning_premium')
    .single();

  if (error) throw error;
  return data.value as WeekendCleaningPremium;
}

export async function updateWeekendPremium(amount: number): Promise<void> {
  const { error } = await workforceClient()
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
  const { data, error } = await workforceClient().rpc('get_timesheet_with_pay', {
    p_start_date: startDate,
    p_end_date: endDate,
    p_employee_ids: employeeIds ?? null,
  });

  if (error) throw error;
  return data || [];
}
