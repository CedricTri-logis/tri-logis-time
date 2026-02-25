'use client';

import { useEffect, useCallback, useState, useRef } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type { RealtimeChannel } from '@supabase/supabase-js';
import type { ConnectionStatus, ShiftRealtimePayload } from '@/types/monitoring';

// Reconnection config
const RECONNECT_BASE_DELAY = 2000;
const RECONNECT_MAX_DELAY = 30000;
const RECONNECT_MAX_ATTEMPTS = 10;

interface UseRealtimeShiftsOptions {
  supervisedEmployeeIds: string[];
  onShiftChange: (payload: ShiftRealtimePayload) => void;
  enabled?: boolean;
}

interface UseRealtimeShiftsReturn {
  connectionStatus: ConnectionStatus;
  lastEventAt: Date | null;
  retry: () => void;
}

/**
 * Hook for subscribing to real-time shift changes via Supabase Realtime.
 * Filters events client-side to only process shifts from supervised employees.
 *
 * Includes automatic reconnection with exponential backoff on errors.
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
  const retryCountRef = useRef(0);
  const retryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);

  // Keep the employee IDs set updated
  useEffect(() => {
    employeeIdsRef.current = new Set(supervisedEmployeeIds);
  }, [supervisedEmployeeIds]);

  // Handle incoming shift change events
  const handleShiftChange = useCallback(
    (payload: ShiftRealtimePayload) => {
      const employeeId = payload.new?.employee_id || payload.old?.employee_id;

      if (!employeeId || !employeeIdsRef.current.has(employeeId)) {
        return;
      }

      setLastEventAt(new Date());
      onShiftChange(payload);
    },
    [onShiftChange]
  );

  // Use a ref so subscribe() always has the latest handler without re-creating
  const handleShiftChangeRef = useRef(handleShiftChange);
  useEffect(() => {
    handleShiftChangeRef.current = handleShiftChange;
  }, [handleShiftChange]);

  // Subscribe to shifts channel — uses refs to avoid circular deps with reconnect
  const subscribe = useCallback(() => {
    if (!mountedRef.current) return;

    // Clean up existing channel
    if (channelRef.current) {
      supabaseClient.removeChannel(channelRef.current);
      channelRef.current = null;
    }

    setConnectionStatus('connecting');

    const channel = supabaseClient
      .channel(`shifts-monitoring-${Date.now()}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'shifts',
        },
        (payload) => {
          handleShiftChangeRef.current(payload as unknown as ShiftRealtimePayload);
        }
      )
      .subscribe((status, err) => {
        if (!mountedRef.current) return;

        if (status === 'SUBSCRIBED') {
          setConnectionStatus('connected');
          retryCountRef.current = 0;
        } else if (status === 'CHANNEL_ERROR') {
          console.error('Shifts realtime subscription error:', err);
          setConnectionStatus('error');
          scheduleReconnect();
        } else if (status === 'TIMED_OUT') {
          console.warn('Shifts realtime subscription timed out');
          setConnectionStatus('error');
          scheduleReconnect();
        } else if (status === 'CLOSED') {
          setConnectionStatus('disconnected');
        }
      });

    channelRef.current = channel;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Schedule a reconnection with exponential backoff
  const scheduleReconnect = useCallback(() => {
    if (retryTimerRef.current) {
      clearTimeout(retryTimerRef.current);
    }

    if (retryCountRef.current >= RECONNECT_MAX_ATTEMPTS) {
      console.warn(`Shifts realtime: max reconnect attempts (${RECONNECT_MAX_ATTEMPTS}) reached`);
      return;
    }

    const delay = Math.min(
      RECONNECT_BASE_DELAY * Math.pow(2, retryCountRef.current),
      RECONNECT_MAX_DELAY
    );
    retryCountRef.current += 1;

    console.log(`Shifts realtime: reconnecting in ${delay}ms (attempt ${retryCountRef.current}/${RECONNECT_MAX_ATTEMPTS})`);

    retryTimerRef.current = setTimeout(() => {
      if (mountedRef.current) {
        subscribe();
      }
    }, delay);
  }, [subscribe]);

  // Manual retry exposed to consumers — resets attempt counter
  const retry = useCallback(() => {
    retryCountRef.current = 0;
    if (retryTimerRef.current) {
      clearTimeout(retryTimerRef.current);
      retryTimerRef.current = null;
    }
    subscribe();
  }, [subscribe]);

  useEffect(() => {
    mountedRef.current = true;

    if (!enabled || supervisedEmployeeIds.length === 0) {
      setConnectionStatus('disconnected');
      return;
    }

    subscribe();

    return () => {
      mountedRef.current = false;
      if (retryTimerRef.current) {
        clearTimeout(retryTimerRef.current);
        retryTimerRef.current = null;
      }
      if (channelRef.current) {
        supabaseClient.removeChannel(channelRef.current);
        channelRef.current = null;
      }
    };
  }, [enabled, supervisedEmployeeIds.length, subscribe]);

  return {
    connectionStatus,
    lastEventAt,
    retry,
  };
}
