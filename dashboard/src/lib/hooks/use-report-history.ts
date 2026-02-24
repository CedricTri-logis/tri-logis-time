'use client';

/**
 * Hook for fetching report history
 * Spec: 013-reports-export
 */

import { useState, useCallback } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type {
  ReportHistoryItem,
  ReportHistoryResponse,
  ReportType,
} from '@/types/reports';

interface UseReportHistoryOptions {
  pageSize?: number;
  reportType?: ReportType;
}

interface UseReportHistoryReturn {
  items: ReportHistoryItem[];
  totalCount: number;
  hasMore: boolean;
  isLoading: boolean;
  error: string | null;
  page: number;
  loadPage: (page: number) => Promise<void>;
  loadMore: () => Promise<void>;
  refresh: () => Promise<void>;
  getDownloadUrl: (filePath: string) => Promise<string | null>;
}

const DEFAULT_PAGE_SIZE = 20;

export function useReportHistory(
  options: UseReportHistoryOptions = {}
): UseReportHistoryReturn {
  const { pageSize = DEFAULT_PAGE_SIZE, reportType } = options;

  const [items, setItems] = useState<ReportHistoryItem[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(0);

  /**
   * Load a specific page of report history
   */
  const loadPage = useCallback(
    async (pageNum: number) => {
      setIsLoading(true);
      setError(null);

      try {
        const { data, error: rpcError } = await supabaseClient.rpc('get_report_history', {
          p_limit: pageSize,
          p_offset: pageNum * pageSize,
          p_report_type: reportType || null,
        });

        if (rpcError) {
          throw new Error(rpcError.message);
        }

        const response = data as ReportHistoryResponse;

        setItems(response.items || []);
        setTotalCount(response.total_count);
        setHasMore(response.has_more);
        setPage(pageNum);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load report history');
      } finally {
        setIsLoading(false);
      }
    },
    [pageSize, reportType]
  );

  /**
   * Load the next page and append to existing items
   */
  const loadMore = useCallback(async () => {
    if (isLoading || !hasMore) return;

    setIsLoading(true);
    setError(null);

    try {
      const nextPage = page + 1;
      const { data, error: rpcError } = await supabaseClient.rpc('get_report_history', {
        p_limit: pageSize,
        p_offset: nextPage * pageSize,
        p_report_type: reportType || null,
      });

      if (rpcError) {
        throw new Error(rpcError.message);
      }

      const response = data as ReportHistoryResponse;

      setItems((prev) => [...prev, ...(response.items || [])]);
      setTotalCount(response.total_count);
      setHasMore(response.has_more);
      setPage(nextPage);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load more');
    } finally {
      setIsLoading(false);
    }
  }, [isLoading, hasMore, page, pageSize, reportType]);

  /**
   * Refresh the list (reload first page)
   */
  const refresh = useCallback(async () => {
    await loadPage(0);
  }, [loadPage]);

  /**
   * Get a signed download URL for a report file
   */
  const getDownloadUrl = useCallback(
    async (filePath: string): Promise<string | null> => {
      try {
        const { data, error: storageError } = await supabaseClient.storage
          .from('reports')
          .createSignedUrl(filePath, 3600); // 1 hour expiry

        if (storageError) {
          console.error('Failed to get download URL:', storageError);
          return null;
        }

        return data?.signedUrl || null;
      } catch (err) {
        console.error('Error getting download URL:', err);
        return null;
      }
    },
    []
  );

  return {
    items,
    totalCount,
    hasMore,
    isLoading,
    error,
    page,
    loadPage,
    loadMore,
    refresh,
    getDownloadUrl,
  };
}
