'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import { toLocalDateString } from '@/lib/utils/date-utils';

export interface SessionDetail {
  session_name: string;
  activity_type: string;
  duration_minutes: number;
  match: boolean | null;
  location_category: 'match' | 'mismatch' | 'office' | 'home' | null;
}

export interface ClusterDetail {
  started_at: string;
  ended_at: string;
  duration_minutes: number;
  physical_location: string;
  physical_location_id: string | null;
  sessions: SessionDetail[];
  uncovered_minutes: number;
  match: boolean | null;
  location_category: 'match' | 'mismatch' | 'office' | 'home' | null;
}

export interface TripDetail {
  started_at: string;
  ended_at: string;
  duration_minutes: number;
}

export interface DayDetail {
  date: string;
  shift_id: string;
  clocked_in_at: string;
  clocked_out_at: string;
  shift_minutes: number;
  session_minutes: number;
  trip_minutes: number;
  clusters: ClusterDetail[];
  trips: TripDetail[];
}

export interface EmployeeSummary {
  total_shift_minutes: number;
  total_trip_minutes: number;
  total_session_minutes: number;
  utilization_pct: number;
  accuracy_pct: number | null;
  total_shifts: number;
  total_sessions: number;
}

interface RpcResponse {
  employee_name: string;
  employee_id: string;
  summary: EmployeeSummary | null;
  days: DayDetail[];
}

interface UseEmployeeUtilizationDetailParams {
  employeeId: string;
  dateFrom: Date;
  dateTo: Date;
}

export function useEmployeeUtilizationDetail({
  employeeId,
  dateFrom,
  dateTo,
}: UseEmployeeUtilizationDetailParams) {
  const { query, result } = useCustom<RpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_employee_utilization_detail',
    },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_date_from: toLocalDateString(dateFrom),
        p_date_to: toLocalDateString(dateTo),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
      enabled: !!employeeId,
    },
  });

  const rawData = result?.data as RpcResponse | undefined;

  const data = useMemo(() => {
    if (!rawData) return null;
    return {
      employeeName: rawData.employee_name,
      employeeId: rawData.employee_id,
      summary: rawData.summary,
      days: rawData.days ?? [],
    };
  }, [rawData]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.error,
  };
}
