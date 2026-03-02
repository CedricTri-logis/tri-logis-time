'use client';

import { useEffect, useState } from 'react';
import { supabaseClient } from '@/lib/supabase/client';

/**
 * Lightweight hook that returns the count of currently active shifts.
 * Subscribes to realtime changes on the shifts table for live updates.
 */
export function useActiveShiftCount(): number {
  const [count, setCount] = useState(0);

  useEffect(() => {
    // Initial fetch
    const fetchCount = async () => {
      const { count: c } = await supabaseClient
        .from('shifts')
        .select('*', { count: 'exact', head: true })
        .eq('status', 'active');
      setCount(c ?? 0);
    };

    fetchCount();

    // Subscribe to realtime changes on shifts
    const channel = supabaseClient
      .channel('sidebar-active-shifts')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'shifts' },
        () => {
          fetchCount();
        }
      )
      .subscribe();

    return () => {
      supabaseClient.removeChannel(channel);
    };
  }, []);

  return count;
}
