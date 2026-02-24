'use client';

/**
 * Report Schedules Hook
 * Spec: 013-reports-export
 *
 * Manages report schedule CRUD operations
 */

import { useState, useEffect, useCallback } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type {
  ReportSchedule,
  ReportSchedulesResponse,
  CreateScheduleResponse,
  UpdateScheduleResponse,
  ReportType,
  ScheduleFrequency,
  ReportConfig,
  ScheduleConfig,
} from '@/types/reports';

export interface UseReportSchedulesOptions {
  autoFetch?: boolean;
  onError?: (error: string) => void;
}

export interface UseReportSchedulesReturn {
  schedules: ReportSchedule[];
  isLoading: boolean;
  error: string | null;
  totalCount: number;
  fetch: () => Promise<void>;
  create: (params: CreateScheduleParams) => Promise<CreateScheduleResponse | null>;
  update: (params: UpdateScheduleParams) => Promise<UpdateScheduleResponse | null>;
  remove: (scheduleId: string) => Promise<boolean>;
  pause: (scheduleId: string) => Promise<boolean>;
  resume: (scheduleId: string) => Promise<boolean>;
}

export interface CreateScheduleParams {
  name: string;
  report_type: ReportType;
  config: ReportConfig;
  frequency: ScheduleFrequency;
  schedule_config: ScheduleConfig;
}

export interface UpdateScheduleParams {
  schedule_id: string;
  name?: string;
  status?: 'active' | 'paused';
  config?: ReportConfig;
  schedule_config?: ScheduleConfig;
}

export function useReportSchedules(
  options: UseReportSchedulesOptions = {}
): UseReportSchedulesReturn {
  const { autoFetch = true, onError } = options;

  const [schedules, setSchedules] = useState<ReportSchedule[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [totalCount, setTotalCount] = useState(0);

  /**
   * Fetch all schedules
   */
  const fetch = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const { data, error: rpcError } = await supabaseClient.rpc('get_report_schedules');

      if (rpcError) {
        throw new Error(rpcError.message);
      }

      const response = data as ReportSchedulesResponse;
      setSchedules(response.items || []);
      setTotalCount(response.total_count || 0);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to fetch schedules';
      setError(message);
      onError?.(message);
    } finally {
      setIsLoading(false);
    }
  }, [onError]);

  /**
   * Create a new schedule
   */
  const create = useCallback(
    async (params: CreateScheduleParams): Promise<CreateScheduleResponse | null> => {
      setError(null);

      try {
        const { data, error: rpcError } = await supabaseClient.rpc('create_report_schedule', {
          p_name: params.name,
          p_report_type: params.report_type,
          p_config: params.config,
          p_frequency: params.frequency,
          p_schedule_config: params.schedule_config,
        });

        if (rpcError) {
          throw new Error(rpcError.message);
        }

        const response = data as CreateScheduleResponse & { error?: string };

        if (response.error) {
          throw new Error(response.error);
        }

        // Refresh the list
        await fetch();

        return response;
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Failed to create schedule';
        setError(message);
        onError?.(message);
        return null;
      }
    },
    [fetch, onError]
  );

  /**
   * Update an existing schedule
   */
  const update = useCallback(
    async (params: UpdateScheduleParams): Promise<UpdateScheduleResponse | null> => {
      setError(null);

      try {
        const { data, error: rpcError } = await supabaseClient.rpc('update_report_schedule', {
          p_schedule_id: params.schedule_id,
          p_name: params.name || null,
          p_status: params.status || null,
          p_config: params.config || null,
          p_schedule_config: params.schedule_config || null,
        });

        if (rpcError) {
          throw new Error(rpcError.message);
        }

        const response = data as UpdateScheduleResponse & { error?: string };

        if (response.error) {
          throw new Error(response.error);
        }

        // Refresh the list
        await fetch();

        return response;
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Failed to update schedule';
        setError(message);
        onError?.(message);
        return null;
      }
    },
    [fetch, onError]
  );

  /**
   * Delete a schedule (soft delete)
   */
  const remove = useCallback(
    async (scheduleId: string): Promise<boolean> => {
      setError(null);

      try {
        const { data, error: rpcError } = await supabaseClient.rpc('delete_report_schedule', {
          p_schedule_id: scheduleId,
        });

        if (rpcError) {
          throw new Error(rpcError.message);
        }

        const response = data as { success: boolean; error?: string };

        if (!response.success) {
          throw new Error(response.error || 'Failed to delete schedule');
        }

        // Refresh the list
        await fetch();

        return true;
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Failed to delete schedule';
        setError(message);
        onError?.(message);
        return false;
      }
    },
    [fetch, onError]
  );

  /**
   * Pause a schedule
   */
  const pause = useCallback(
    async (scheduleId: string): Promise<boolean> => {
      const result = await update({ schedule_id: scheduleId, status: 'paused' });
      return result !== null;
    },
    [update]
  );

  /**
   * Resume a paused schedule
   */
  const resume = useCallback(
    async (scheduleId: string): Promise<boolean> => {
      const result = await update({ schedule_id: scheduleId, status: 'active' });
      return result !== null;
    },
    [update]
  );

  // Auto-fetch on mount
  useEffect(() => {
    if (autoFetch) {
      fetch();
    }
  }, [autoFetch, fetch]);

  return {
    schedules,
    isLoading,
    error,
    totalCount,
    fetch,
    create,
    update,
    remove,
    pause,
    resume,
  };
}
