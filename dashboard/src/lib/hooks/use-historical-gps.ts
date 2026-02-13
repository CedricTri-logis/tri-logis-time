'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type {
  HistoricalGpsPoint,
  HistoricalGpsPointRow,
  ShiftHistorySummary,
  ShiftHistorySummaryRow,
  SupervisedEmployee,
  SupervisedEmployeeRow,
  MultiShiftGpsPoint,
  MultiShiftGpsPointRow,
  transformHistoricalGpsPointRow,
  transformShiftHistorySummaryRow,
  transformSupervisedEmployeeRow,
  transformMultiShiftGpsPointRow,
} from '@/types/history';

/**
 * Hook to fetch historical GPS trail for a single completed shift
 */
export function useHistoricalTrail(shiftId: string | null) {
  const { query, result } = useCustom<HistoricalGpsPointRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_historical_shift_trail',
    },
    config: {
      payload: {
        p_shift_id: shiftId,
      },
    },
    queryOptions: {
      enabled: !!shiftId,
    },
  });

  const rawData = result?.data as HistoricalGpsPointRow[] | undefined;

  const trail: HistoricalGpsPoint[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      id: row.id,
      latitude: row.latitude,
      longitude: row.longitude,
      accuracy: row.accuracy,
      capturedAt: new Date(row.captured_at),
    }));
  }, [rawData]);

  return {
    trail,
    isLoading: query.isLoading,
    error: query.isError ? (query.error as unknown as Error)?.message ?? 'Unknown error' : null,
    refetch: query.refetch,
  };
}

/**
 * Hook to fetch shift history for an employee
 */
export function useShiftHistory(params: {
  employeeId: string | null;
  startDate: string;
  endDate: string;
}) {
  const { employeeId, startDate, endDate } = params;

  const { query, result } = useCustom<ShiftHistorySummaryRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_employee_shift_history',
    },
    config: {
      payload: {
        p_employee_id: employeeId,
        p_start_date: startDate,
        p_end_date: endDate,
      },
    },
    queryOptions: {
      enabled: !!employeeId && !!startDate && !!endDate,
    },
  });

  const rawData = result?.data as ShiftHistorySummaryRow[] | undefined;

  const shifts: ShiftHistorySummary[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      id: row.id,
      employeeId: row.employee_id,
      employeeName: row.employee_name,
      clockedInAt: new Date(row.clocked_in_at),
      clockedOutAt: new Date(row.clocked_out_at),
      durationMinutes: row.duration_minutes,
      gpsPointCount: row.gps_point_count,
      totalDistanceKm: row.total_distance_km,
      clockInLatitude: row.clock_in_latitude,
      clockInLongitude: row.clock_in_longitude,
      clockOutLatitude: row.clock_out_latitude,
      clockOutLongitude: row.clock_out_longitude,
    }));
  }, [rawData]);

  return {
    shifts,
    isLoading: query.isLoading,
    error: query.isError ? (query.error as unknown as Error)?.message ?? 'Unknown error' : null,
    refetch: query.refetch,
  };
}

/**
 * Hook to fetch supervised employees list for filter dropdown
 */
export function useSupervisedEmployees() {
  const { query, result } = useCustom<SupervisedEmployeeRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_supervised_employees',
    },
    queryOptions: {
      staleTime: 5 * 60 * 1000, // Cache for 5 minutes
    },
  });

  const rawData = result?.data as SupervisedEmployeeRow[] | undefined;

  const employees: SupervisedEmployee[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      id: row.id,
      fullName: row.full_name,
      email: row.email,
      employeeId: row.employee_id,
    }));
  }, [rawData]);

  return {
    employees,
    isLoading: query.isLoading,
    error: query.isError ? (query.error as unknown as Error)?.message ?? 'Unknown error' : null,
    refetch: query.refetch,
  };
}

/**
 * Hook to fetch GPS trails for multiple shifts at once
 */
export function useMultiShiftTrails(shiftIds: string[]) {
  const { query, result } = useCustom<MultiShiftGpsPointRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_multi_shift_trails',
    },
    config: {
      payload: {
        p_shift_ids: shiftIds,
      },
    },
    queryOptions: {
      enabled: shiftIds.length > 0 && shiftIds.length <= 10,
    },
  });

  const rawData = result?.data as MultiShiftGpsPointRow[] | undefined;

  // Group points by shift ID
  const trailsByShift: Map<string, MultiShiftGpsPoint[]> = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return new Map();

    const map = new Map<string, MultiShiftGpsPoint[]>();

    rawData.forEach((row) => {
      const point: MultiShiftGpsPoint = {
        id: row.id,
        shiftId: row.shift_id,
        shiftDate: row.shift_date,
        latitude: row.latitude,
        longitude: row.longitude,
        accuracy: row.accuracy,
        capturedAt: new Date(row.captured_at),
      };

      const existing = map.get(row.shift_id) ?? [];
      existing.push(point);
      map.set(row.shift_id, existing);
    });

    return map;
  }, [rawData]);

  // All points in a flat array
  const allPoints: MultiShiftGpsPoint[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      id: row.id,
      shiftId: row.shift_id,
      shiftDate: row.shift_date,
      latitude: row.latitude,
      longitude: row.longitude,
      accuracy: row.accuracy,
      capturedAt: new Date(row.captured_at),
    }));
  }, [rawData]);

  // Get unique shift dates
  const shiftDates: string[] = useMemo(() => {
    const dates = new Set<string>();
    trailsByShift.forEach((points) => {
      if (points.length > 0) {
        dates.add(points[0].shiftDate);
      }
    });
    return Array.from(dates).sort();
  }, [trailsByShift]);

  return {
    trailsByShift,
    allPoints,
    shiftDates,
    isLoading: query.isLoading,
    error: query.isError ? (query.error as unknown as Error)?.message ?? 'Unknown error' : null,
    refetch: query.refetch,
  };
}
