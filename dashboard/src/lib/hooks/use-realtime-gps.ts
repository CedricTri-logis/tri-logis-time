'use client';

import { useEffect, useCallback, useState, useRef } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type { RealtimeChannel } from '@supabase/supabase-js';
import type { ConnectionStatus, GpsPointRealtimePayload, LocationPoint } from '@/types/monitoring';

// Batch interval for flushing GPS updates (in milliseconds)
const GPS_BATCH_INTERVAL = 1000;

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
}

/**
 * Hook for subscribing to real-time GPS point insertions via Supabase Realtime.
 * Filters events client-side to only process GPS points from supervised employees.
 *
 * Supports batching for high-frequency updates:
 * - When batchUpdates=true, collects updates and flushes every second
 * - Uses onBatchGpsPoints for batched updates, falls back to onGpsPoint
 * - Keeps only latest location per employee in batch (deduplication)
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
      // Clear any pending updates when batching is disabled
      if (flushIntervalRef.current) {
        clearInterval(flushIntervalRef.current);
        flushIntervalRef.current = null;
      }
      // Flush any remaining updates
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
      // Flush remaining updates on cleanup
      if (pendingUpdatesRef.current.size > 0) {
        flushBatchedUpdates();
      }
    };
  }, [batchUpdates, enabled, flushBatchedUpdates]);

  // Handle incoming GPS point events
  const handleGpsPoint = useCallback(
    (payload: GpsPointRealtimePayload) => {
      const employeeId = payload.new?.employee_id;

      // Only process events for supervised employees
      if (!employeeId || !employeeIdsRef.current.has(employeeId)) {
        return;
      }

      const location: LocationPoint = {
        latitude: payload.new.latitude,
        longitude: payload.new.longitude,
        accuracy: payload.new.accuracy,
        capturedAt: new Date(payload.new.captured_at),
        isStale: false, // New points are always fresh
      };

      if (batchUpdates) {
        // Queue update for batching - only keep latest per employee
        pendingUpdatesRef.current.set(employeeId, location);
      } else {
        // Immediate update
        setLastEventAt(new Date());
        onGpsPoint(employeeId, location);
      }
    },
    [onGpsPoint, batchUpdates]
  );

  useEffect(() => {
    if (!enabled || supervisedEmployeeIds.length === 0) {
      setConnectionStatus('disconnected');
      return;
    }

    setConnectionStatus('connecting');

    // Create the realtime channel for GPS points
    const channel = supabaseClient
      .channel('gps-monitoring')
      .on(
        'postgres_changes',
        {
          event: 'INSERT', // GPS points are immutable, only INSERT events
          schema: 'public',
          table: 'gps_points',
        },
        (payload) => {
          handleGpsPoint(payload as unknown as GpsPointRealtimePayload);
        }
      )
      .subscribe((status, err) => {
        if (status === 'SUBSCRIBED') {
          setConnectionStatus('connected');
        } else if (status === 'CHANNEL_ERROR') {
          console.error('GPS realtime subscription error:', err);
          setConnectionStatus('error');
        } else if (status === 'TIMED_OUT') {
          console.warn('GPS realtime subscription timed out, retrying...');
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
  }, [enabled, supervisedEmployeeIds.length, handleGpsPoint]);

  return {
    connectionStatus,
    lastEventAt,
  };
}
