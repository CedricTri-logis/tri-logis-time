'use client';

/**
 * Hook for generating reports with sync/async handling
 * Spec: 013-reports-export
 */

import { useState, useCallback, useRef, useEffect } from 'react';
import { useCustom } from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';
import type {
  ReportConfig,
  ReportType,
  GenerateReportResponse,
  ReportJobStatusResponse,
  ReportGenerationState,
  RecordCountResponse,
} from '@/types/reports';
import { resolveDateRange, ASYNC_THRESHOLD } from '@/lib/validations/reports';

interface UseReportGenerationOptions {
  onSuccess?: (downloadUrl: string) => void;
  onError?: (error: string) => void;
}

interface UseReportGenerationReturn {
  generate: (reportType: ReportType, config: ReportConfig) => Promise<void>;
  state: ReportGenerationState;
  jobId: string | null;
  progress: number;
  recordCount: number | null;
  downloadUrl: string | null;
  error: string | null;
  isAsync: boolean;
  reset: () => void;
  countRecords: (reportType: ReportType, config: ReportConfig) => Promise<number>;
}

const POLL_INTERVAL = 3000; // 3 seconds
const MAX_POLL_ATTEMPTS = 120; // 6 minutes max polling

export function useReportGeneration(
  options: UseReportGenerationOptions = {}
): UseReportGenerationReturn {
  const { onSuccess, onError } = options;

  const [state, setState] = useState<ReportGenerationState>('idle');
  const [jobId, setJobId] = useState<string | null>(null);
  const [progress, setProgress] = useState(0);
  const [recordCount, setRecordCount] = useState<number | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isAsync, setIsAsync] = useState(false);

  const pollIntervalRef = useRef<number | null>(null);
  const pollAttemptsRef = useRef(0);

  // Clean up polling on unmount
  useEffect(() => {
    return () => {
      if (pollIntervalRef.current) {
        clearInterval(pollIntervalRef.current);
      }
    };
  }, []);

  /**
   * Reset the hook state
   */
  const reset = useCallback(() => {
    if (pollIntervalRef.current) {
      clearInterval(pollIntervalRef.current);
      pollIntervalRef.current = null;
    }
    setState('idle');
    setJobId(null);
    setProgress(0);
    setRecordCount(null);
    setDownloadUrl(null);
    setError(null);
    setIsAsync(false);
    pollAttemptsRef.current = 0;
  }, []);

  /**
   * Count records to determine if async processing is needed
   */
  const countRecords = useCallback(
    async (reportType: ReportType, config: ReportConfig): Promise<number> => {
      setState('counting');

      const { start, end } = resolveDateRange(config.date_range);
      const employeeIds = Array.isArray(config.employee_filter)
        ? config.employee_filter
        : null;

      const { data, error: rpcError } = await supabaseClient.rpc('count_report_records', {
        p_report_type: reportType,
        p_start_date: start,
        p_end_date: end,
        p_employee_ids: employeeIds,
      });

      if (rpcError) {
        throw new Error(rpcError.message);
      }

      const count = (data as RecordCountResponse)?.count || 0;
      setRecordCount(count);
      return count;
    },
    []
  );

  /**
   * Poll for job status
   */
  const pollJobStatus = useCallback(
    async (currentJobId: string) => {
      const { data, error: rpcError } = await supabaseClient.rpc('get_report_job_status', {
        p_job_id: currentJobId,
      });

      if (rpcError) {
        setError(rpcError.message);
        setState('failed');
        onError?.(rpcError.message);
        if (pollIntervalRef.current) {
          clearInterval(pollIntervalRef.current);
        }
        return;
      }

      const status = data as ReportJobStatusResponse;

      if (status.progress_percent) {
        setProgress(status.progress_percent);
      }

      if (status.status === 'completed') {
        if (pollIntervalRef.current) {
          clearInterval(pollIntervalRef.current);
        }

        // Get signed URL for download
        if (status.file_path) {
          const { data: signedData } = await supabaseClient.storage
            .from('reports')
            .createSignedUrl(status.file_path, 3600); // 1 hour

          if (signedData?.signedUrl) {
            setDownloadUrl(signedData.signedUrl);
            setState('completed');
            setProgress(100);
            onSuccess?.(signedData.signedUrl);
          }
        }
      } else if (status.status === 'failed') {
        if (pollIntervalRef.current) {
          clearInterval(pollIntervalRef.current);
        }
        setError(status.error_message || 'Report generation failed');
        setState('failed');
        onError?.(status.error_message || 'Report generation failed');
      }

      // Check max polling attempts
      pollAttemptsRef.current += 1;
      if (pollAttemptsRef.current >= MAX_POLL_ATTEMPTS) {
        if (pollIntervalRef.current) {
          clearInterval(pollIntervalRef.current);
        }
        setError('Report generation timed out');
        setState('failed');
        onError?.('Report generation timed out');
      }
    },
    [onSuccess, onError]
  );

  /**
   * Generate report
   */
  const generate = useCallback(
    async (reportType: ReportType, config: ReportConfig) => {
      try {
        reset();
        setState('generating');

        // Resolve date range if using preset
        const resolvedConfig: ReportConfig = {
          ...config,
          date_range: {
            ...config.date_range,
            ...resolveDateRange(config.date_range),
          },
        };

        // Call generate_report RPC
        const { data, error: rpcError } = await supabaseClient.rpc('generate_report', {
          p_report_type: reportType,
          p_config: resolvedConfig,
        });

        if (rpcError) {
          throw new Error(rpcError.message);
        }

        const response = data as GenerateReportResponse;

        if ('error' in response && response.error) {
          throw new Error(response.error as string);
        }

        setJobId(response.job_id);
        setIsAsync(response.is_async || false);

        if (response.is_async) {
          // Start polling for async jobs
          setState('polling');
          setProgress(10);
          pollAttemptsRef.current = 0;
          pollIntervalRef.current = window.setInterval(
            () => pollJobStatus(response.job_id),
            POLL_INTERVAL
          );
        } else {
          // For sync jobs, we need to invoke the Edge Function and wait
          setState('generating');
          setProgress(30);

          // Get the current user ID
          const { data: { user } } = await supabaseClient.auth.getUser();

          if (!user) {
            throw new Error('Not authenticated');
          }

          // Invoke Edge Function
          const { data: funcData, error: funcError } = await supabaseClient.functions.invoke(
            'generate-report',
            {
              body: {
                job_id: response.job_id,
                report_type: reportType,
                config: resolvedConfig,
                user_id: user.id,
              },
            }
          );

          if (funcError) {
            throw new Error(funcError.message);
          }

          if (funcData?.success && funcData?.file_path) {
            // Get signed URL
            const { data: signedData } = await supabaseClient.storage
              .from('reports')
              .createSignedUrl(funcData.file_path, 3600);

            if (signedData?.signedUrl) {
              setDownloadUrl(signedData.signedUrl);
              setRecordCount(funcData.record_count);
              setState('completed');
              setProgress(100);
              onSuccess?.(signedData.signedUrl);
            }
          } else {
            throw new Error(funcData?.error || 'Report generation failed');
          }
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Unknown error';
        setError(message);
        setState('failed');
        onError?.(message);
      }
    },
    [reset, pollJobStatus, onSuccess, onError]
  );

  return {
    generate,
    state,
    jobId,
    progress,
    recordCount,
    downloadUrl,
    error,
    isAsync,
    reset,
    countRecords,
  };
}
