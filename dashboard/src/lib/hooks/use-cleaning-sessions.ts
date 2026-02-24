'use client';

import { useCustom, useCustomMutation } from '@refinedev/core';
import { useMemo, useCallback, useState } from 'react';
import type {
  CleaningSession,
  CleaningSessionRow,
  CleaningSummary,
  BuildingStats,
  EmployeeCleaningStats,
} from '@/types/cleaning';
import { transformCleaningSessionRow } from '@/types/cleaning';

export interface CleaningSessionFilters {
  buildingId?: string;
  employeeId?: string;
  dateFrom: Date;
  dateTo: Date;
  status?: string;
  limit?: number;
  offset?: number;
}

interface DashboardRpcResponse {
  summary: {
    total_sessions: number;
    completed: number;
    in_progress: number;
    auto_closed: number;
    avg_duration_minutes: number;
    flagged_count: number;
  };
  sessions: CleaningSessionRow[];
  total_count: number;
}

/**
 * Hook to fetch cleaning sessions with filters for dashboard
 */
export function useCleaningSessions(filters: CleaningSessionFilters) {
  const {
    buildingId,
    employeeId,
    dateFrom,
    dateTo,
    status,
    limit = 50,
    offset = 0,
  } = filters;

  const { query, result } = useCustom<DashboardRpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_cleaning_dashboard',
    },
    config: {
      payload: {
        p_building_id: buildingId || null,
        p_employee_id: employeeId || null,
        p_date_from: dateFrom.toISOString().split('T')[0],
        p_date_to: dateTo.toISOString().split('T')[0],
        p_limit: limit,
        p_offset: offset,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 15 * 1000,
    },
  });

  const rawData = result?.data as DashboardRpcResponse | undefined;

  const sessions: CleaningSession[] = useMemo(() => {
    if (!rawData?.sessions || !Array.isArray(rawData.sessions)) return [];
    let filtered = rawData.sessions;
    if (status) {
      filtered = filtered.filter((s) => s.status === status);
    }
    return filtered.map(transformCleaningSessionRow);
  }, [rawData, status]);

  const summary: CleaningSummary = useMemo(() => {
    if (!rawData?.summary) {
      return {
        totalSessions: 0,
        completed: 0,
        inProgress: 0,
        autoClosed: 0,
        avgDurationMinutes: 0,
        flaggedCount: 0,
      };
    }
    const s = rawData.summary;
    return {
      totalSessions: s.total_sessions,
      completed: s.completed,
      inProgress: s.in_progress,
      autoClosed: s.auto_closed,
      avgDurationMinutes: s.avg_duration_minutes,
      flaggedCount: s.flagged_count,
    };
  }, [rawData]);

  const totalCount = rawData?.total_count ?? 0;

  return {
    sessions,
    summary,
    totalCount,
    isLoading: query.isLoading,
    error: query.error,
    refetch: query.refetch,
  };
}

interface BuildingStatsRow {
  building_id: string;
  building_name: string;
  total_studios: number;
  cleaned_today: number;
  in_progress: number;
  not_started: number;
  avg_duration_minutes: number;
}

/**
 * Hook for per-building cleaning stats
 */
export function useCleaningStatsByBuilding(dateFrom: Date, dateTo: Date) {
  const { query, result } = useCustom<BuildingStatsRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_cleaning_stats_by_building',
    },
    config: {
      payload: {
        p_date_from: dateFrom.toISOString().split('T')[0],
        p_date_to: dateTo.toISOString().split('T')[0],
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
    },
  });

  const rawData = result?.data as BuildingStatsRow[] | undefined;

  const stats: BuildingStats[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      buildingId: row.building_id,
      buildingName: row.building_name,
      totalStudios: row.total_studios,
      cleanedToday: row.cleaned_today,
      inProgress: row.in_progress,
      notStarted: row.not_started,
      avgDurationMinutes: row.avg_duration_minutes,
    }));
  }, [rawData]);

  return {
    stats,
    isLoading: query.isLoading,
    error: query.error,
  };
}

/**
 * Hook for per-employee cleaning stats
 */
export function useEmployeeCleaningStats(
  employeeId: string | undefined,
  dateFrom: Date,
  dateTo: Date
) {
  const { query, result } = useCustom<Record<string, unknown>>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_employee_cleaning_stats',
    },
    config: {
      payload: {
        p_employee_id: employeeId || null,
        p_date_from: dateFrom.toISOString().split('T')[0],
        p_date_to: dateTo.toISOString().split('T')[0],
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000,
      enabled: !!employeeId,
    },
  });

  const rawData = result?.data as Record<string, unknown> | undefined;

  const stats: EmployeeCleaningStats | null = useMemo(() => {
    if (!rawData) return null;
    return {
      employeeName: (rawData.employee_name as string) ?? '',
      totalSessions: (rawData.total_sessions as number) ?? 0,
      avgDurationMinutes: (rawData.avg_duration_minutes as number) ?? 0,
      sessionsByBuilding: Array.isArray(rawData.sessions_by_building)
        ? (rawData.sessions_by_building as Array<Record<string, unknown>>).map(
            (b) => ({
              buildingName: (b.building_name as string) ?? '',
              count: (b.count as number) ?? 0,
              avgDuration: (b.avg_duration as number) ?? 0,
            })
          )
        : [],
      flaggedSessions: (rawData.flagged_sessions as number) ?? 0,
    };
  }, [rawData]);

  return {
    stats,
    isLoading: query.isLoading,
    error: query.error,
  };
}

/**
 * Hook for supervisor mutation actions
 */
export function useCleaningSessionMutations() {
  const { mutateAsync } = useCustomMutation();
  const [isClosing, setIsClosing] = useState(false);

  const closeSession = useCallback(
    async (sessionId: string) => {
      setIsClosing(true);
      try {
        await mutateAsync({
          url: '',
          method: 'post',
          meta: {
            rpc: 'manually_close_session',
          },
          values: {
            p_session_id: sessionId,
            p_closed_by: null, // Server will use auth.uid()
          },
        });
      } finally {
        setIsClosing(false);
      }
    },
    [mutateAsync]
  );

  return {
    closeSession,
    isClosing,
  };
}
