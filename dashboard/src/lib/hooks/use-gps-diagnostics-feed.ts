'use client';

import { useCustom } from '@refinedev/core';
import { useMemo, useState, useCallback, useEffect } from 'react';
import type { GpsFeedRow, GpsFeedItem, DiagnosticSeverity } from '@/types/gps-diagnostics';
import { transformFeedRow } from '@/types/gps-diagnostics';

interface FeedCursor {
  time: string;
  id: string;
}

export function useGpsDiagnosticsFeed(
  startDate: string,
  endDate: string,
  severities: DiagnosticSeverity[],
  employeeId?: string | null,
  autoRefreshEnabled: boolean = true,
) {
  const [accumulatedItems, setAccumulatedItems] = useState<GpsFeedItem[]>([]);
  const [cursor, setCursor] = useState<FeedCursor | null>(null);
  const [hasMore, setHasMore] = useState(true);

  const { query, result } = useCustom<GpsFeedRow[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_gps_diagnostics_feed' },
    config: {
      payload: {
        p_start_date: startDate,
        p_end_date: endDate,
        p_severities: severities,
        ...(employeeId ? { p_employee_id: employeeId } : {}),
        ...(cursor ? { p_cursor_time: cursor.time, p_cursor_id: cursor.id } : {}),
        p_limit: 50,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 15_000,
      refetchInterval: !cursor && autoRefreshEnabled ? 30_000 : false,
    },
  });

  const raw = result?.data as GpsFeedRow[] | undefined;

  // Transform raw data (pure computation)
  const currentPage = useMemo(() => {
    if (!raw || !Array.isArray(raw)) return [];
    return raw.map(transformFeedRow);
  }, [raw]);

  // Side effect: update hasMore when data changes
  useEffect(() => {
    if (raw) {
      setHasMore(raw.length === 50);
    }
  }, [raw]);

  // Merge accumulated items with current page for "load more"
  const items = useMemo(() => {
    if (cursor) return [...accumulatedItems, ...currentPage];
    return currentPage;
  }, [cursor, accumulatedItems, currentPage]);

  const loadMore = useCallback(() => {
    if (items.length === 0) return;
    const last = items[items.length - 1];
    setAccumulatedItems(items);
    setCursor({ time: last.createdAt.toISOString(), id: last.id });
  }, [items]);

  const reset = useCallback(() => {
    setAccumulatedItems([]);
    setCursor(null);
    setHasMore(true);
  }, []);

  return {
    items,
    isLoading: query.isLoading,
    error: query.isError ? ((query.error as unknown as Error)?.message ?? 'Unknown error') : null,
    hasMore,
    loadMore,
    reset,
    refetch: query.refetch,
  };
}
