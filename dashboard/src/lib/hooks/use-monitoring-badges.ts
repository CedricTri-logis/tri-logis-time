'use client';

import { useEffect, useState, useCallback, useRef } from 'react';
import { supabaseClient, workforceClient } from '@/lib/supabase/client';
import type { MonitoredTeamRow } from '@/types/monitoring';
import { STALENESS_THRESHOLDS } from '@/types/monitoring';

export interface MonitoringBadgeCounts {
  /** On-shift employees with fresh GPS (<5min) */
  fresh: number;
  /** On-shift employees with stale GPS (5-15min) */
  stale: number;
  /** On-shift employees with very stale GPS (>15min) or no GPS */
  veryStale: number;
  /** On-shift employees currently on lunch break */
  onLunch: number;
  /** Total on-shift employees */
  total: number;
}

const RECATEGORIZE_INTERVAL = 30_000; // Re-evaluate staleness every 30s

/**
 * Lightweight hook for sidebar badges showing on-shift employee counts
 * categorized by GPS freshness. Subscribes to both shifts and gps_points
 * for real-time updates, plus periodic re-categorization as GPS ages.
 */
export function useMonitoringBadges(): MonitoringBadgeCounts {
  const [rows, setRows] = useState<MonitoredTeamRow[]>([]);
  const [counts, setCounts] = useState<MonitoringBadgeCounts>({ fresh: 0, stale: 0, veryStale: 0, onLunch: 0, total: 0 });
  const mountedRef = useRef(true);

  const categorize = useCallback((data: MonitoredTeamRow[]) => {
    const now = Date.now();
    let fresh = 0;
    let stale = 0;
    let veryStale = 0;
    let onLunch = 0;

    for (const row of data) {
      if (row.shift_status !== 'on-shift') continue;
      if (row.is_on_lunch) {
        onLunch++;
        continue;
      }
      if (!row.latest_captured_at) {
        veryStale++;
        continue;
      }
      const ageMinutes = (now - new Date(row.latest_captured_at).getTime()) / 60_000;
      if (ageMinutes <= STALENESS_THRESHOLDS.FRESH_MAX_MINUTES) {
        fresh++;
      } else if (ageMinutes <= STALENESS_THRESHOLDS.STALE_MAX_MINUTES) {
        stale++;
      } else {
        veryStale++;
      }
    }

    setCounts({ fresh, stale, veryStale, onLunch, total: fresh + stale + veryStale + onLunch });
  }, []);

  const fetchData = useCallback(async () => {
    const { data } = await workforceClient().rpc('get_monitored_team', {
      p_search: null,
      p_shift_status: 'all',
    });
    if (!mountedRef.current) return;
    const rows = (data as MonitoredTeamRow[] | null) ?? [];
    setRows(rows);
    categorize(rows);
  }, [categorize]);

  useEffect(() => {
    mountedRef.current = true;
    fetchData();

    // Subscribe to shift changes (clock-in/out)
    const shiftsChannel = supabaseClient
      .channel('sidebar-shifts')
      .on(
        'postgres_changes',
        { event: '*', schema: 'workforce', table: 'shifts' },
        () => { fetchData(); }
      )
      .subscribe();

    // Subscribe to GPS point insertions
    const gpsChannel = supabaseClient
      .channel('sidebar-gps')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'workforce', table: 'gps_points' },
        () => { fetchData(); }
      )
      .subscribe();

    // Subscribe to lunch break changes (start/end)
    const lunchChannel = supabaseClient
      .channel('sidebar-lunch')
      .on(
        'postgres_changes',
        { event: '*', schema: 'workforce', table: 'lunch_breaks' },
        () => { fetchData(); }
      )
      .subscribe();

    // Periodic re-categorization as GPS ages (fresh -> stale -> lost)
    const recatInterval = setInterval(() => {
      if (mountedRef.current) {
        setRows((current) => {
          categorize(current);
          return current;
        });
      }
    }, RECATEGORIZE_INTERVAL);

    return () => {
      mountedRef.current = false;
      supabaseClient.removeChannel(shiftsChannel);
      supabaseClient.removeChannel(gpsChannel);
      supabaseClient.removeChannel(lunchChannel);
      clearInterval(recatInterval);
    };
  }, [fetchData, categorize]);

  return counts;
}
