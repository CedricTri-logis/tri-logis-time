'use client';

import { useState, useEffect, useMemo, useCallback } from 'react';
import { getPayrollPeriodReport } from '@/lib/api/payroll';
import type {
  PayrollReportRow,
  PayrollEmployeeSummary,
  PayrollCategoryGroup,
  PayPeriod,
} from '@/types/payroll';

const MIN_HOURS_FOR_BREAK_WARNING = 5 * 60; // 300 minutes

export function usePayrollReport(period: PayPeriod) {
  const [rows, setRows] = useState<PayrollReportRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async (silent = false) => {
    if (!silent) setIsLoading(true);
    setError(null);
    try {
      const data = await getPayrollPeriodReport(period.start, period.end);
      setRows(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, [period.start, period.end]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Group rows by employee into summaries
  const employees = useMemo((): PayrollEmployeeSummary[] => {
    const byEmployee = new Map<string, PayrollReportRow[]>();
    for (const row of rows) {
      const existing = byEmployee.get(row.employee_id) || [];
      existing.push(row);
      byEmployee.set(row.employee_id, existing);
    }

    return Array.from(byEmployee.entries()).map(([, days]) => {
      const first = days[0];
      const daysWorked = days.filter(d => d.day_approval_status !== 'no_shift').length;
      const daysApproved = days.filter(d => d.day_approval_status === 'approved').length;
      const daysWithoutBreak = days.filter(
        d => d.approved_minutes >= MIN_HOURS_FOR_BREAK_WARNING && d.break_minutes < 30
      ).length;

      const totalApprovedMin = days.reduce((s, d) => s + d.approved_minutes, 0);
      const totalSessionMin = days.reduce(
        (s, d) => s + d.cleaning_minutes + d.maintenance_minutes + d.admin_minutes,
        0
      );
      const coverage = totalApprovedMin > 0 ? Math.round((totalSessionMin / totalApprovedMin) * 100) : 0;

      return {
        employee_id: first.employee_id,
        full_name: first.full_name,
        employee_id_code: first.employee_id_code,
        pay_type: first.pay_type,
        primary_category: first.primary_category,
        secondary_categories: first.secondary_categories,
        total_approved_minutes: totalApprovedMin,
        total_break_minutes: days.reduce((s, d) => s + d.break_minutes, 0),
        total_callback_bonus_minutes: days.reduce((s, d) => s + d.callback_bonus_minutes, 0),
        days_without_break: daysWithoutBreak,
        total_break_deduction_minutes: days.reduce((s, d) => s + d.break_deduction_minutes, 0),
        total_rejected_minutes: days.reduce((s, d) => s + d.rejected_minutes, 0),
        work_session_coverage_pct: coverage,
        total_premium: days.reduce((s, d) => s + d.premium_amount, 0),
        total_base: days.reduce((s, d) => s + d.base_amount, 0),
        total_amount: days.reduce((s, d) => s + d.total_amount, 0),
        total_callback_bonus_amount: days.reduce((s, d) => s + (d.callback_bonus_amount || 0), 0),
        days_approved: daysApproved,
        days_worked: daysWorked,
        payroll_status: first.payroll_status,
        payroll_approved_by: first.payroll_approved_by,
        payroll_approved_at: first.payroll_approved_at,
        hourly_rate: first.pay_type === 'hourly'
          ? first.hourly_rate
          : first.annual_salary ? Math.round((first.annual_salary / 2080) * 100) / 100 : null,
        hourly_rate_display: first.pay_type === 'hourly'
          ? (first.hourly_rate ? `${first.hourly_rate.toFixed(2)} $/h` : '—')
          : (first.annual_salary ? `~${(first.annual_salary / 2080).toFixed(2)} $/h` : '—'),
        annual_salary: first.annual_salary,
        // Hour bank (from first row — per-employee fields)
        bank_deposit_hours: first.bank_deposit_hours ?? 0,
        bank_deposit_amount: first.bank_deposit_amount ?? 0,
        bank_withdrawal_hours: first.bank_withdrawal_hours ?? 0,
        bank_withdrawal_amount: first.bank_withdrawal_amount ?? 0,
        bank_net_amount: (first.bank_withdrawal_amount ?? 0) - (first.bank_deposit_amount ?? 0),
        bank_balance_dollars: first.bank_balance_dollars ?? 0,
        bank_balance_hours: first.bank_balance_hours ?? 0,
        // Sick leave (from first row — per-employee fields)
        sick_leave_hours: first.sick_leave_hours ?? 0,
        sick_leave_amount: first.sick_leave_amount ?? 0,
        sick_leave_remaining: first.sick_leave_remaining ?? 14,
        days,
      };
    });
  }, [rows]);

  // Group employees by primary category
  const categoryGroups = useMemo((): PayrollCategoryGroup[] => {
    const groups = new Map<string, PayrollEmployeeSummary[]>();
    for (const emp of employees) {
      const cat = emp.primary_category || 'Non catégorisé';
      const existing = groups.get(cat) || [];
      existing.push(emp);
      groups.set(cat, existing);
    }

    const order = ['menage', 'maintenance', 'renovation', 'admin', 'Non catégorisé'];
    return order
      .filter(cat => groups.has(cat))
      .map(cat => {
        const emps = groups.get(cat)!;
        return {
          category: cat,
          employees: emps,
          totals: {
            approved_minutes: emps.reduce((s, e) => s + e.total_approved_minutes, 0),
            base_amount: emps.reduce((s, e) => s + e.total_base, 0),
            premium_amount: emps.reduce((s, e) => s + e.total_premium, 0),
            total_amount: emps.reduce((s, e) => s + e.total_amount, 0),
            break_deduction_minutes: emps.reduce((s, e) => s + e.total_break_deduction_minutes, 0),
            rejected_minutes: emps.reduce((s, e) => s + e.total_rejected_minutes, 0),
            callback_bonus_minutes: emps.reduce((s, e) => s + e.total_callback_bonus_minutes, 0),
          },
        };
      });
  }, [employees]);

  const grandTotal = useMemo(() => ({
    approved_minutes: employees.reduce((s, e) => s + e.total_approved_minutes, 0),
    base_amount: employees.reduce((s, e) => s + e.total_base, 0),
    premium_amount: employees.reduce((s, e) => s + e.total_premium, 0),
    total_amount: employees.reduce((s, e) => s + e.total_amount, 0),
    break_deduction_minutes: employees.reduce((s, e) => s + e.total_break_deduction_minutes, 0),
    rejected_minutes: employees.reduce((s, e) => s + e.total_rejected_minutes, 0),
    callback_bonus_minutes: employees.reduce((s, e) => s + e.total_callback_bonus_minutes, 0),
  }), [employees]);

  const silentRefetch = useCallback(() => fetchData(true), [fetchData]);

  return {
    rows,
    employees,
    categoryGroups,
    grandTotal,
    isLoading,
    error,
    refetch: fetchData,
    silentRefetch,
  };
}
