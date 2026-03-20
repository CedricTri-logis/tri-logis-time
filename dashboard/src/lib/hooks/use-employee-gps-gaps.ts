'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsGapRow, GpsGap } from '@/types/gps-diagnostics';
import { transformGapRow } from '@/types/gps-diagnostics';

export function useEmployeeGpsGaps(
  employeeId: string | null,
  startDate: string,
  endDate: string,
) {
  const { query, result } = useCustom<GpsGapRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_employee_gps_gaps' },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_start_date: startDate,
        p_end_date: endDate,
        p_min_gap_minutes: 5,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!employeeId,
      staleTime: 60_000,
    },
  });

  const raw = result?.data as GpsGapRow[] | undefined;

  const data: GpsGap[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformGapRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
