'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsSummaryRow, GpsSummaryPeriod } from '@/types/gps-diagnostics';
import { transformSummary } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsSummary(
  startDate: string,
  endDate: string,
  compareStartDate: string,
  compareEndDate: string,
  employeeId?: string | null,
) {
  const { query, result } = useCustom<GpsSummaryRow>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_summary' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_compare_start_date: compareStartDate,
        p_compare_end_date: compareEndDate,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsSummaryRow | undefined;

  const data = useMemo(() => {
    if (!raw?.primary) return null;
    return transformSummary(raw);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
    refetch: query.refetch,
  };
}
