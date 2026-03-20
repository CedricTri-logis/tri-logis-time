'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsRankingRow, GpsRankedEmployee } from '@/types/gps-diagnostics';
import { transformRankingRow } from '@/types/gps-diagnostics';

export function useGpsDiagnosticsRanking(startDate: string, endDate: string) {
  const { query, result } = useCustom<GpsRankingRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_ranking' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsRankingRow[] | undefined;

  const data: GpsRankedEmployee[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformRankingRow);
  }, [raw]);

  return {
    data,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
