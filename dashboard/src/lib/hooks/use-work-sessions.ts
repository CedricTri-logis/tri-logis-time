'use client';

import { useCustom, useCustomMutation } from '@refinedev/core';
import { useMemo, useCallback, useState } from 'react';
import { toLocalDateString } from '@/lib/utils/date-utils';
import type {
  WorkSession,
  WorkSessionRow,
  WorkSessionSummary,
  WorkSessionDashboardRpcResponse,
  ActivityType,
  WorkSessionStatus,
} from '@/types/work-session';
import { transformWorkSessionRow } from '@/types/work-session';

export interface WorkSessionFilters {
  activityType?: ActivityType;
  buildingId?: string;
  employeeId?: string;
  dateFrom: Date;
  dateTo: Date;
  status?: WorkSessionStatus;
  limit?: number;
  offset?: number;
}

/**
 * Hook to fetch work sessions with filters for dashboard.
 * Calls the get_work_sessions_dashboard RPC.
 */
export function useWorkSessions(filters: WorkSessionFilters) {
  const {
    activityType,
    buildingId,
    employeeId,
    dateFrom,
    dateTo,
    status,
    limit = 50,
    offset = 0,
  } = filters;

  const { query, result } = useCustom<WorkSessionDashboardRpcResponse>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_work_sessions_dashboard',
    },
    config: {
      payload: {
        p_activity_type: activityType || null,
        p_building_id: buildingId || null,
        p_employee_id: employeeId || null,
        p_date_from: toLocalDateString(dateFrom),
        p_date_to: toLocalDateString(dateTo),
        p_status: status || null,
        p_limit: limit,
        p_offset: offset,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 15 * 1000,
    },
  });

  const rawData = result?.data as WorkSessionDashboardRpcResponse | undefined;

  const sessions: WorkSession[] = useMemo(() => {
    if (!rawData?.sessions || !Array.isArray(rawData.sessions)) return [];
    return rawData.sessions.map(transformWorkSessionRow);
  }, [rawData]);

  const summary: WorkSessionSummary = useMemo(() => {
    if (!rawData?.summary) {
      return {
        totalSessions: 0,
        completed: 0,
        inProgress: 0,
        autoClosed: 0,
        manuallyClosed: 0,
        avgDurationMinutes: null,
        flaggedCount: 0,
        byType: { cleaning: 0, maintenance: 0, admin: 0 },
      };
    }
    const s = rawData.summary;
    return {
      totalSessions: s.total_sessions,
      completed: s.completed,
      inProgress: s.in_progress,
      autoClosed: s.auto_closed,
      manuallyClosed: s.manually_closed,
      avgDurationMinutes: s.avg_duration_minutes,
      flaggedCount: s.flagged_count,
      byType: {
        cleaning: s.by_type.cleaning,
        maintenance: s.by_type.maintenance,
        admin: s.by_type.admin,
      },
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

/**
 * Hook for manually closing a work session from the dashboard.
 * Calls the manually_close_work_session RPC.
 */
export function useManualCloseWorkSession() {
  const { mutateAsync } = useCustomMutation();
  const [isClosing, setIsClosing] = useState(false);

  const closeSession = useCallback(
    async (sessionId: string, employeeId: string) => {
      setIsClosing(true);
      try {
        await mutateAsync({
          url: '',
          method: 'post',
          meta: {
            rpc: 'manually_close_work_session',
          },
          values: {
            p_session_id: sessionId,
            p_employee_id: employeeId,
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
