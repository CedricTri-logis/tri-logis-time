'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsTrendRow, GpsTrendPoint } from '@/types/gps-diagnostics';
import { transformTrendRow } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsTrend(
  startDate: string,
  endDate: string,
  employeeId?: string | null,
) {
  const { query, result } = useCustom<GpsTrendRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_trend' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsTrendRow[] | undefined;

  const data: GpsTrendPoint[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformTrendRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
