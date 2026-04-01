'use client';

import { useEffect, useState, useCallback, useRef } from 'react';
import { supabaseClient, workforceClient } from '@/lib/supabase/client';
import type { MonitoredTeamRow } from '@/types/monitoring';

export interface TeamStats {
  total: number;
  onShift: number;
  offShift: number;
  neverInstalled: number;
  lastUpdated: Date | null;
  isLoading: boolean;
}

/**
 * Lightweight hook that fetches unfiltered team stats (always 'all', no search).
 * Subscribes to shift changes for real-time updates.
 * Used by the stats panel so it doesn't change when page filters are applied.
 */
export function useTeamStats(): TeamStats {
  const [stats, setStats] = useState<TeamStats>({
    total: 0,
    onShift: 0,
    offShift: 0,
    neverInstalled: 0,
    lastUpdated: null,
    isLoading: true,
  });
  const mountedRef = useRef(true);

  const fetchStats = useCallback(async () => {
    const { data } = await workforceClient().rpc('get_monitored_team', {
      p_search: null,
      p_shift_status: 'all',
    });
    if (!mountedRef.current) return;

    const rows = (data as MonitoredTeamRow[] | null) ?? [];
    let onShift = 0;
    let offShift = 0;
    let neverInstalled = 0;
    for (const row of rows) {
      if (row.shift_status === 'on-shift') onShift++;
      else if (row.shift_status === 'off-shift') offShift++;
      else if (row.shift_status === 'never-installed') neverInstalled++;
    }

    setStats({
      total: rows.length,
      onShift,
      offShift,
      neverInstalled,
      lastUpdated: new Date(),
      isLoading: false,
    });
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    fetchStats();

    const channel = supabaseClient
      .channel('stats-shifts')
      .on(
        'postgres_changes',
        { event: '*', schema: 'workforce', table: 'shifts' },
        () => { fetchStats(); }
      )
      .subscribe();

    return () => {
      mountedRef.current = false;
      supabaseClient.removeChannel(channel);
    };
  }, [fetchStats]);

  return stats;
}
