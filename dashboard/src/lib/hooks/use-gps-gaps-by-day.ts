'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type { GpsGapByDayRow, GpsGapByDay, GapsByDayGroup, GapsByEmployeeGroup } from '@/types/gps-diagnostics';
import { transformGapByDayRow } from '@/types/gps-diagnostics';

export function useGpsGapsByDay(
  startDate: string,
  endDate: string,
  employeeId?: string | null,
  minGapMinutes: number = 5,
) {
  const { query, result } = useCustom<GpsGapByDayRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_gaps_by_day' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_min_gap_minutes: minGapMinutes,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30_000,
      refetchInterval: 60_000,
    },
  });

  const raw = result?.data as GpsGapByDayRow[] | undefined;

  // Group flat rows into day → employee → gaps structure
  const grouped: GapsByDayGroup[] = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    const items = raw.map(transformGapByDayRow);

    const dayMap = new Map<string, Map<string, GpsGapByDay[]>>();

    for (const item of items) {
      if (!dayMap.has(item.day)) dayMap.set(item.day, new Map());
      const empMap = dayMap.get(item.day)!;
      if (!empMap.has(item.employeeId)) empMap.set(item.employeeId, []);
      empMap.get(item.employeeId)!.push(item);
    }

    const result: GapsByDayGroup[] = [];

    for (const [day, empMap] of dayMap) {
      const employees: GapsByEmployeeGroup[] = [];

      for (const [empId, gaps] of empMap) {
        const first = gaps[0];
        const totalMinutes = gaps.reduce((sum, g) => sum + g.gapMinutes, 0);
        employees.push({
          employeeId: empId,
          fullName: first.fullName,
          devicePlatform: first.devicePlatform,
          deviceModel: first.deviceModel,
          gaps: gaps
            .map((g) => ({ gapStart: g.gapStart, gapEnd: g.gapEnd, gapMinutes: g.gapMinutes }))
            .sort((a, b) => a.gapStart.getTime() - b.gapStart.getTime()),
          totalMinutes: Math.round(totalMinutes * 10) / 10,
        });
      }

      // Sort employees by total minutes descending
      employees.sort((a, b) => b.totalMinutes - a.totalMinutes);

      result.push({
        day,
        totalGaps: employees.reduce((sum, e) => sum + e.gaps.length, 0),
        totalEmployees: employees.length,
        employees,
      });
    }

    // Days already sorted DESC from RPC, but ensure it
    result.sort((a, b) => b.day.localeCompare(a.day));

    return result;
  }, [raw]);

  return {
    data: grouped,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
  };
}
