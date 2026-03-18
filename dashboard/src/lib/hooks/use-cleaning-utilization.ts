'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import { toLocalDateString } from '@/lib/utils/date-utils';

export interface CleaningUtilizationEmployee {
  employee_id: string;
  employee_name: string;
  total_shift_minutes: number;
  total_trip_minutes: number;
  total_session_minutes: number;
  available_minutes: number;
  utilization_pct: number;
  accuracy_pct: number | null;
  short_term_unit_minutes: number;
  short_term_common_minutes: number;
  cleaning_long_term_minutes: number;
  maintenance_long_term_minutes: number;
  office_minutes: number;
  total_sessions: number;
  total_shifts: number;
}

interface RpcResponse {
  employees: CleaningUtilizationEmployee[];
}

interface UseCleaningUtilizationParams {
  dateFrom: Date;
  dateTo: Date;
  employeeId?: string;
}

export function useCleaningUtilization({
  dateFrom,
  dateTo,
  employeeId,
}: UseCleaningUtilizationParams) {
  const { query, result } = useCustom<RpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_cleaning_utilization_report',
    },
    config: {
      payload: {
        p_date_from: toLocalDateString(dateFrom),
        p_date_to: toLocalDateString(dateTo),
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
    },
  });

  const rawData = result?.data as RpcResponse | undefined;

  const employees = useMemo(() => {
    if (!rawData?.employees) return [];
    return rawData.employees;
  }, [rawData]);

  const totals = useMemo(() => {
    if (employees.length === 0) return null;
    const sum = (key: keyof CleaningUtilizationEmployee) =>
      employees.reduce((acc, e) => acc + ((e[key] as number) ?? 0), 0);

    const totalShift = sum('total_shift_minutes');
    const totalTrip = sum('total_trip_minutes');
    const totalSession = sum('total_session_minutes');
    const available = Math.max(totalShift - totalTrip, 0);

    const totalGpsEmployees = employees.filter((e) => e.accuracy_pct !== null);
    const avgAccuracy =
      totalGpsEmployees.length > 0
        ? totalGpsEmployees.reduce((a, e) => a + (e.accuracy_pct ?? 0), 0) /
          totalGpsEmployees.length
        : null;

    return {
      total_shift_minutes: totalShift,
      total_trip_minutes: totalTrip,
      total_session_minutes: totalSession,
      available_minutes: available,
      utilization_pct: available > 0 ? (totalSession / available) * 100 : 0,
      accuracy_pct: avgAccuracy !== null ? Math.round(avgAccuracy * 10) / 10 : null,
      short_term_unit_minutes: sum('short_term_unit_minutes'),
      short_term_common_minutes: sum('short_term_common_minutes'),
      cleaning_long_term_minutes: sum('cleaning_long_term_minutes'),
      maintenance_long_term_minutes: sum('maintenance_long_term_minutes'),
      office_minutes: sum('office_minutes'),
      employee_count: employees.length,
    };
  }, [employees]);

  return {
    employees,
    totals,
    isLoading: query.isLoading,
    error: query.error,
    refetch: query.refetch,
  };
}
