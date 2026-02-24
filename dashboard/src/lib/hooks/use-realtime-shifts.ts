'use client';

import { useEffect, useCallback, useState, useRef } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type { RealtimeChannel } from '@supabase/supabase-js';
import type { ConnectionStatus, ShiftRealtimePayload } from '@/types/monitoring';

interface UseRealtimeShiftsOptions {
  supervisedEmployeeIds: string[];
  onShiftChange: (payload: ShiftRealtimePayload) => void;
  enabled?: boolean;
}

interface UseRealtimeShiftsReturn {
  connectionStatus: ConnectionStatus;
  lastEventAt: Date | null;
}

/**
 * Hook for subscribing to real-time shift changes via Supabase Realtime.
 * Filters events client-side to only process shifts from supervised employees.
 */
export function useRealtimeShifts({
  supervisedEmployeeIds,
  onShiftChange,
  enabled = true,
}: UseRealtimeShiftsOptions): UseRealtimeShiftsReturn {
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('connecting');
  const [lastEventAt, setLastEventAt] = useState<Date | null>(null);
  const channelRef = useRef<RealtimeChannel | null>(null);
  const employeeIdsRef = useRef<Set<string>>(new Set(supervisedEmployeeIds));

  // Keep the employee IDs set updated
  useEffect(() => {
    employeeIdsRef.current = new Set(supervisedEmployeeIds);
  }, [supervisedEmployeeIds]);

  // Handle incoming shift change events
  const handleShiftChange = useCallback(
    (payload: ShiftRealtimePayload) => {
      const employeeId = payload.new?.employee_id || payload.old?.employee_id;

      // Only process events for supervised employees
      if (!employeeId || !employeeIdsRef.current.has(employeeId)) {
        return;
      }

      setLastEventAt(new Date());
      onShiftChange(payload);
    },
    [onShiftChange]
  );

  useEffect(() => {
    if (!enabled || supervisedEmployeeIds.length === 0) {
      setConnectionStatus('disconnected');
      return;
    }

    setConnectionStatus('connecting');

    // Create the realtime channel for shifts
    const channel = supabaseClient
      .channel('shifts-monitoring')
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'shifts',
        },
        (payload) => {
          handleShiftChange(payload as unknown as ShiftRealtimePayload);
        }
      )
      .subscribe((status, err) => {
        if (status === 'SUBSCRIBED') {
          setConnectionStatus('connected');
        } else if (status === 'CHANNEL_ERROR') {
          console.error('Shifts realtime subscription error:', err);
          setConnectionStatus('error');
        } else if (status === 'TIMED_OUT') {
          console.warn('Shifts realtime subscription timed out, retrying...');
          setConnectionStatus('connecting');
        } else if (status === 'CLOSED') {
          setConnectionStatus('disconnected');
        }
      });

    channelRef.current = channel;

    // Cleanup on unmount or when dependencies change
    return () => {
      if (channelRef.current) {
        supabaseClient.removeChannel(channelRef.current);
        channelRef.current = null;
      }
    };
  }, [enabled, supervisedEmployeeIds.length, handleShiftChange]);

  return {
    connectionStatus,
    lastEventAt,
  };
}
