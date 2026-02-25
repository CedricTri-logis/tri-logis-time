'use client';

import { useEffect, useCallback, useState, useRef } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type { RealtimeChannel } from '@supabase/supabase-js';
import type { ConnectionStatus, GpsPointRealtimePayload, LocationPoint } from '@/types/monitoring';

// Batch interval for flushing GPS updates (in milliseconds)
const GPS_BATCH_INTERVAL = 1000;

// Reconnection config (no max attempts — monitoring dashboard must stay live)
const RECONNECT_BASE_DELAY = 2000;
const RECONNECT_MAX_DELAY = 30000;

interface UseRealtimeGpsOptions {
  supervisedEmployeeIds: string[];
  onGpsPoint: (employeeId: string, location: LocationPoint) => void;
  onBatchGpsPoints?: (updates: Map<string, LocationPoint>) => void;
  enabled?: boolean;
  batchUpdates?: boolean;
}

interface UseRealtimeGpsReturn {
  connectionStatus: ConnectionStatus;
  lastEventAt: Date | null;
  retry: () => void;
}

/**
 * Hook for subscribing to real-time GPS point insertions via Supabase Realtime.
 * Filters events client-side to only process GPS points from supervised employees.
 *
 * Supports batching for high-frequency updates:
 * - When batchUpdates=true, collects updates and flushes every second
 * - Uses onBatchGpsPoints for batched updates, falls back to onGpsPoint
 * - Keeps only latest location per employee in batch (deduplication)
 *
 * Includes automatic reconnection with exponential backoff on errors.
 */
export function useRealtimeGps({
  supervisedEmployeeIds,
  onGpsPoint,
  onBatchGpsPoints,
  enabled = true,
  batchUpdates = false,
}: UseRealtimeGpsOptions): UseRealtimeGpsReturn {
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('connecting');
  const [lastEventAt, setLastEventAt] = useState<Date | null>(null);
  const channelRef = useRef<RealtimeChannel | null>(null);
  const employeeIdsRef = useRef<Set<string>>(new Set(supervisedEmployeeIds));
  const retryCountRef = useRef(0);
  const retryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);

  // Batching state - keeps latest update per employee
  const pendingUpdatesRef = useRef<Map<string, LocationPoint>>(new Map());
  const flushIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Keep the employee IDs set updated
  useEffect(() => {
    employeeIdsRef.current = new Set(supervisedEmployeeIds);
  }, [supervisedEmployeeIds]);

  // Flush batched updates
  const flushBatchedUpdates = useCallback(() => {
    if (pendingUpdatesRef.current.size === 0) return;

    const updates = new Map(pendingUpdatesRef.current);
    pendingUpdatesRef.current.clear();

    // Use batch callback if available, otherwise call individual callbacks
    if (onBatchGpsPoints) {
      onBatchGpsPoints(updates);
    } else {
      updates.forEach((location, employeeId) => {
        onGpsPoint(employeeId, location);
      });
    }

    setLastEventAt(new Date());
  }, [onGpsPoint, onBatchGpsPoints]);

  // Set up batch flushing interval
  useEffect(() => {
    if (!batchUpdates || !enabled) {
      if (flushIntervalRef.current) {
        clearInterval(flushIntervalRef.current);
        flushIntervalRef.current = null;
      }
      if (pendingUpdatesRef.current.size > 0) {
        flushBatchedUpdates();
      }
      return;
    }

    flushIntervalRef.current = setInterval(flushBatchedUpdates, GPS_BATCH_INTERVAL);

    return () => {
      if (flushIntervalRef.current) {
        clearInterval(flushIntervalRef.current);
        flushIntervalRef.current = null;
      }
      if (pendingUpdatesRef.current.size > 0) {
        flushBatchedUpdates();
      }
    };
  }, [batchUpdates, enabled, flushBatchedUpdates]);

  // Handle incoming GPS point events
  const handleGpsPoint = useCallback(
    (payload: GpsPointRealtimePayload) => {
      const employeeId = payload.new?.employee_id;

      if (!employeeId || !employeeIdsRef.current.has(employeeId)) {
        return;
      }

      const location: LocationPoint = {
        latitude: payload.new.latitude,
        longitude: payload.new.longitude,
        accuracy: payload.new.accuracy,
        capturedAt: new Date(payload.new.captured_at),
        isStale: false,
      };

      if (batchUpdates) {
        pendingUpdatesRef.current.set(employeeId, location);
      } else {
        setLastEventAt(new Date());
        onGpsPoint(employeeId, location);
      }
    },
    [onGpsPoint, batchUpdates]
  );

  // Use a ref for handleGpsPoint so subscribe() always has the latest without re-creating
  const handleGpsPointRef = useRef(handleGpsPoint);
  useEffect(() => {
    handleGpsPointRef.current = handleGpsPoint;
  }, [handleGpsPoint]);

  // Subscribe to GPS channel — uses refs to avoid circular deps with reconnect
  const subscribe = useCallback(() => {
    if (!mountedRef.current) return;

    // Clean up existing channel
    if (channelRef.current) {
      supabaseClient.removeChannel(channelRef.current);
      channelRef.current = null;
    }

    setConnectionStatus('connecting');

    const channel = supabaseClient
      .channel(`gps-monitoring-${Date.now()}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'gps_points',
        },
        (payload) => {
          handleGpsPointRef.current(payload as unknown as GpsPointRealtimePayload);
        }
      )
      .subscribe((status, err) => {
        if (!mountedRef.current) return;

        if (status === 'SUBSCRIBED') {
          setConnectionStatus('connected');
          retryCountRef.current = 0;
        } else if (status === 'CHANNEL_ERROR') {
          console.error('GPS realtime subscription error:', err);
          setConnectionStatus('error');
          scheduleReconnect();
        } else if (status === 'TIMED_OUT') {
          console.warn('GPS realtime subscription timed out');
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

    const delay = Math.min(
      RECONNECT_BASE_DELAY * Math.pow(2, retryCountRef.current),
      RECONNECT_MAX_DELAY
    );
    retryCountRef.current += 1;

    console.log(`GPS realtime: reconnecting in ${delay}ms (attempt ${retryCountRef.current})`);

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
