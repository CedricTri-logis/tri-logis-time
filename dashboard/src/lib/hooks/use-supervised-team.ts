'use client';

import { useState, useCallback, useMemo, useEffect, useRef } from 'react';
import { useCustom } from '@refinedev/core';
import { useRealtimeShifts } from './use-realtime-shifts';
import { useRealtimeGps } from './use-realtime-gps';
import type {
  MonitoredEmployee,
  MonitoredTeamRow,
  ShiftRealtimePayload,
  LocationPoint,
  ConnectionStatus,
} from '@/types/monitoring';
import { transformMonitoredTeamRow } from '@/types/monitoring';

interface UseSupervisedTeamOptions {
  search?: string;
  shiftStatus?: 'all' | 'on-shift' | 'off-shift' | 'never-installed';
  enabled?: boolean;
}

interface UseSupervisedTeamReturn {
  team: MonitoredEmployee[];
  isLoading: boolean;
  error: Error | null;
  refetch: () => void;
  lastUpdated: Date | null;
  connectionStatus: ConnectionStatus;
  shiftsConnectionStatus: ConnectionStatus;
  gpsConnectionStatus: ConnectionStatus;
  retryConnection: () => void;
}

/**
 * Hook for fetching and managing supervised team data with real-time updates.
 * Combines initial data fetch with WebSocket subscriptions for live updates.
 */
export function useSupervisedTeam({
  search,
  shiftStatus = 'all',
  enabled = true,
}: UseSupervisedTeamOptions = {}): UseSupervisedTeamReturn {
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);

  // Fetch initial team data using the RPC function
  const {
    query,
    result,
  } = useCustom<MonitoredTeamRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_monitored_team',
    },
    config: {
      payload: {
        p_search: search || null,
        p_shift_status: shiftStatus,
      },
    },
    queryOptions: {
      enabled,
      refetchInterval: 30000, // Fallback polling every 30 seconds
      staleTime: 15000,
    },
  });

  const isLoading = query.isLoading;
  const isError = query.isError;
  const queryError = query.error;
  const refetch = query.refetch;

  // Transform raw data to typed objects
  const [localTeam, setLocalTeam] = useState<MonitoredEmployee[]>([]);
  const rawTeam = result?.data;
  const prevRawTeamRef = useRef<string | null>(null);

  // Update local team when query data changes
  useEffect(() => {
    if (rawTeam && Array.isArray(rawTeam)) {
      // Only update if data actually changed (compare full payload including GPS)
      const dataKey = JSON.stringify(rawTeam);
      if (prevRawTeamRef.current !== dataKey) {
        prevRawTeamRef.current = dataKey;
        const transformed = (rawTeam as MonitoredTeamRow[]).map(transformMonitoredTeamRow);
        setLocalTeam(transformed);
        setLastUpdated(new Date());
      }
    }
  }, [rawTeam]);

  // Get employee IDs for realtime subscriptions
  const employeeIds = useMemo(
    () => localTeam.map((e) => e.id),
    [localTeam]
  );

  // Handle shift change events
  const handleShiftChange = useCallback((payload: ShiftRealtimePayload) => {
    const employeeId = payload.new?.employee_id || payload.old?.employee_id;
    if (!employeeId) return;

    setLocalTeam((current) =>
      current.map((employee) => {
        if (employee.id !== employeeId) return employee;

        // Handle clock-in (INSERT) or status update
        if (payload.eventType === 'INSERT' || payload.new?.status === 'active') {
          const newShift = payload.new;
          if (!newShift) return employee;

          return {
            ...employee,
            shiftStatus: 'on-shift' as const,
            currentShift: {
              id: newShift.id,
              clockedInAt: new Date(newShift.clocked_in_at),
              clockInLocation: newShift.clock_in_location,
              clockInAccuracy: newShift.clock_in_accuracy,
            },
          };
        }

        // Handle clock-out (UPDATE with status=completed)
        if (payload.eventType === 'UPDATE' && payload.new?.status === 'completed') {
          return {
            ...employee,
            shiftStatus: 'off-shift' as const,
            currentShift: null,
            currentLocation: null,
          };
        }

        return employee;
      })
    );

    setLastUpdated(new Date());
  }, []);

  // Handle individual GPS point events (fallback for non-batched mode)
  const handleGpsPoint = useCallback((employeeId: string, location: LocationPoint) => {
    setLocalTeam((current) =>
      current.map((employee) => {
        if (employee.id !== employeeId) return employee;

        return {
          ...employee,
          currentLocation: location,
        };
      })
    );

    setLastUpdated(new Date());
  }, []);

  // Handle batched GPS updates - apply all updates in a single state update
  const handleBatchGpsPoints = useCallback((updates: Map<string, LocationPoint>) => {
    setLocalTeam((current) =>
      current.map((employee) => {
        const newLocation = updates.get(employee.id);
        if (!newLocation) return employee;

        return {
          ...employee,
          currentLocation: newLocation,
        };
      })
    );

    setLastUpdated(new Date());
  }, []);

  // Subscribe to real-time shift updates
  const { connectionStatus: shiftsConnectionStatus, retry: retryShifts } = useRealtimeShifts({
    supervisedEmployeeIds: employeeIds,
    onShiftChange: handleShiftChange,
    enabled: enabled && employeeIds.length > 0,
  });

  // Subscribe to real-time GPS updates with batching for performance
  const { connectionStatus: gpsConnectionStatus, retry: retryGps } = useRealtimeGps({
    supervisedEmployeeIds: employeeIds,
    onGpsPoint: handleGpsPoint,
    onBatchGpsPoints: handleBatchGpsPoints,
    enabled: enabled && employeeIds.length > 0,
    batchUpdates: true, // Enable batching for high-frequency updates
  });

  // Manual retry for both channels
  const retryConnection = useCallback(() => {
    retryShifts();
    retryGps();
  }, [retryShifts, retryGps]);

  // Determine overall connection status
  // Only show 'error' when BOTH channels fail — if one works, polling covers the other
  const connectionStatus: ConnectionStatus = useMemo(() => {
    if (shiftsConnectionStatus === 'connected' && gpsConnectionStatus === 'connected') {
      return 'connected';
    }
    if (shiftsConnectionStatus === 'connected' || gpsConnectionStatus === 'connected') {
      // At least one channel is working — partial connectivity, treat as connected
      return 'connected';
    }
    if (shiftsConnectionStatus === 'error' && gpsConnectionStatus === 'error') {
      return 'error';
    }
    if (shiftsConnectionStatus === 'disconnected' && gpsConnectionStatus === 'disconnected') {
      return 'disconnected';
    }
    return 'connecting';
  }, [shiftsConnectionStatus, gpsConnectionStatus]);

  // Handle refetch
  const handleRefetch = useCallback(() => {
    refetch();
  }, [refetch]);

  return {
    team: localTeam,
    isLoading,
    error: isError ? (queryError as unknown as Error) : null,
    refetch: handleRefetch,
    lastUpdated,
    connectionStatus,
    shiftsConnectionStatus,
    gpsConnectionStatus,
    retryConnection,
  };
}
