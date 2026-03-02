'use client';

import { useEffect, useState } from 'react';
import { supabaseClient } from '@/lib/supabase/client';

/**
 * Lightweight hook that returns the count of on-shift employees
 * from the supervised team (same source as the monitoring page).
 * Subscribes to realtime shift changes for live updates.
 */
export function useActiveShiftCount(): number {
  const [count, setCount] = useState(0);

  useEffect(() => {
    const fetchCount = async () => {
      const { data } = await supabaseClient.rpc('get_monitored_team', {
        p_search: null,
        p_shift_status: 'on-shift',
      });
      setCount(data?.length ?? 0);
    };

    fetchCount();

    // Re-fetch when shifts change (clock-in/out)
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
