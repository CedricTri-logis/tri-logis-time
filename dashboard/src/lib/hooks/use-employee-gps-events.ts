'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsEventRow, GpsEvent } from '@/types/gps-diagnostics';
import { transformEventRow } from '@/types/gps-diagnostics';

export function useEmployeeGpsEvents(
  employeeId: string | null,
  startDate: string,
  endDate: string,
) {
  const { query, result } = useCustom<GpsEventRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_employee_gps_events' },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_start_date: startDate,
        p_end_date: endDate,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!employeeId,
      staleTime: 60_000,
    },
  });

  const raw = result?.data as GpsEventRow[] | undefined;

  const data: GpsEvent[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformEventRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
