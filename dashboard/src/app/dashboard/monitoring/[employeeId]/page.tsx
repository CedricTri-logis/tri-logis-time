'use client';

import { useState, useCallback, useMemo, useEffect, useRef, use } from 'react';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { useCustom } from '@refinedev/core';
import { ArrowLeft, RefreshCw, Wifi, WifiOff, Map, Navigation } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { ShiftDetailCard } from '@/components/monitoring/shift-detail-card';
import { TimelineBar } from '@/components/timeline/timeline-bar';
import { TimelineSummaryCard } from '@/components/timeline/timeline-summary';
import { useRealtimeGps } from '@/lib/hooks/use-realtime-gps';
import { useTimelineSegments } from '@/lib/hooks/use-timeline-segments';
import type {
  EmployeeCurrentShiftRow,
  ShiftDetailRow,
  GpsTrailRow,
  EmployeeCurrentShift,
  GpsTrailPoint,
  LocationPoint,
  ConnectionStatus,
} from '@/types/monitoring';
import { transformGpsTrailRow } from '@/types/monitoring';
import type { TimelineSegment } from '@/types/location';

// Dynamically import the GPS trail map to avoid SSR issues
const GpsTrailMap = dynamic(
  () => import('@/components/monitoring/gps-trail-map').then((mod) => mod.GpsTrailMap),
  {
    ssr: false,
    loading: () => <MapSkeleton />,
  }
);

// Dynamically import the segmented trail map
const SegmentedTrailMap = dynamic(
  () => import('@/components/timeline/segmented-trail-map').then((mod) => mod.SegmentedTrailMap),
  {
    ssr: false,
    loading: () => <MapSkeleton />,
  }
);

type MapViewMode = 'basic' | 'segmented';

interface PageProps {
  params: Promise<{ employeeId: string }>;
}

export default function EmployeeMonitoringPage({ params }: PageProps) {
  const { employeeId } = use(params);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [mapViewMode, setMapViewMode] = useState<MapViewMode>('segmented');

  // Fetch employee's current shift
  const {
    query: shiftQuery,
    result: shiftResult,
  } = useCustom<EmployeeCurrentShiftRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_employee_current_shift',
    },
    config: {
      payload: {
        p_employee_id: employeeId,
      },
    },
    queryOptions: {
      refetchInterval: 60000,
      staleTime: 30000,
    },
  });

  const shiftLoading = shiftQuery.isLoading;
  const refetchShift = shiftQuery.refetch;

  // Transform shift data
  const currentShift: EmployeeCurrentShift | null = useMemo(() => {
    const data = shiftResult?.data;
    if (!data || !Array.isArray(data) || data.length === 0) return null;

    const row = data[0] as EmployeeCurrentShiftRow;
    if (!row || !row.shift_id) return null;

    return {
      shiftId: row.shift_id,
      clockedInAt: new Date(row.clocked_in_at),
      clockInLocation:
        row.clock_in_latitude !== null && row.clock_in_longitude !== null
          ? { latitude: row.clock_in_latitude, longitude: row.clock_in_longitude }
          : null,
      clockInAccuracy: row.clock_in_accuracy,
      gpsPointCount: row.gps_point_count,
      latestLocation:
        row.latest_latitude !== null && row.latest_longitude !== null && row.latest_captured_at
          ? {
              latitude: row.latest_latitude,
              longitude: row.latest_longitude,
              accuracy: row.latest_accuracy ?? 0,
              capturedAt: new Date(row.latest_captured_at),
              isStale: false,
            }
          : null,
    };
  }, [shiftResult]);

  // Fetch GPS trail for active shift
  const {
    query: trailQuery,
    result: trailResult,
  } = useCustom<GpsTrailRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_shift_gps_trail',
    },
    config: {
      payload: {
        p_shift_id: currentShift?.shiftId ?? '',
      },
    },
    queryOptions: {
      enabled: !!currentShift?.shiftId,
      refetchInterval: 60000,
      staleTime: 30000,
    },
  });

  const trailLoading = trailQuery.isLoading;
  const refetchTrail = trailQuery.refetch;

  // Fetch shift detail (for employee name)
  const { result: shiftDetailResult } = useCustom<ShiftDetailRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_shift_detail',
    },
    config: {
      payload: {
        p_shift_id: currentShift?.shiftId ?? '',
      },
    },
    queryOptions: {
      enabled: !!currentShift?.shiftId,
      staleTime: 300000, // 5 min — name doesn't change
    },
  });

  // Transform GPS trail data
  const [localTrail, setLocalTrail] = useState<GpsTrailPoint[]>([]);
  const trailData = trailResult?.data;
  const prevTrailDataRef = useRef<string | null>(null);

  useEffect(() => {
    if (trailData && Array.isArray(trailData)) {
      // Only update if data actually changed (compare by JSON string)
      const dataKey = JSON.stringify(trailData.map((r: GpsTrailRow) => r.id));
      if (prevTrailDataRef.current !== dataKey) {
        prevTrailDataRef.current = dataKey;
        setLocalTrail((trailData as GpsTrailRow[]).map(transformGpsTrailRow));
      }
    }
  }, [trailData]);

  // Handle real-time GPS updates for this employee
  const handleGpsPoint = useCallback(
    (empId: string, location: LocationPoint) => {
      if (empId !== employeeId) return;

      // Add new point to trail
      setLocalTrail((current) => {
        const newPoint: GpsTrailPoint = {
          id: `realtime-${Date.now()}`,
          latitude: location.latitude,
          longitude: location.longitude,
          accuracy: location.accuracy,
          capturedAt: location.capturedAt,
        };
        return [...current, newPoint];
      });

      setLastUpdated(new Date());
    },
    [employeeId]
  );

  const { connectionStatus } = useRealtimeGps({
    supervisedEmployeeIds: [employeeId],
    onGpsPoint: handleGpsPoint,
    enabled: !!currentShift,
  });

  // Timeline segments for shift
  const {
    segments,
    summary: timelineSummary,
    shiftDuration,
    isLoading: timelineLoading,
  } = useTimelineSegments(currentShift?.shiftId ?? null);

  // Selected segment state for timeline interaction
  const [selectedSegment, setSelectedSegment] = useState<TimelineSegment | null>(null);

  const handleSegmentClick = useCallback((segment: TimelineSegment) => {
    setSelectedSegment((current) =>
      current?.segmentIndex === segment.segmentIndex ? null : segment
    );
  }, []);

  // Refresh handler
  const [isRefreshing, setIsRefreshing] = useState(false);
  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await Promise.all([refetchShift(), refetchTrail()]);
    } finally {
      setTimeout(() => setIsRefreshing(false), 500);
    }
  }, [refetchShift, refetchTrail]);

  // Loading state
  const isLoading = shiftLoading;

  // Get employee name from shift detail RPC
  const employeeName = useMemo(() => {
    const data = shiftDetailResult?.data;
    if (!data || !Array.isArray(data) || data.length === 0) return 'Employee';
    return (data[0] as ShiftDetailRow).employee_name || 'Employee';
  }, [shiftDetailResult]);
  const employeeIdDisplay = employeeId;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-4">
          <Link href="/dashboard/monitoring">
            <Button variant="ghost" size="icon">
              <ArrowLeft className="h-5 w-5" />
            </Button>
          </Link>
          <div>
            <h2 className="text-2xl font-bold text-slate-900">Shift Details</h2>
            <p className="text-sm text-slate-500">
              Real-time monitoring for employee
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <ConnectionIndicator status={connectionStatus} />
          <Button
            variant="outline"
            size="sm"
            onClick={handleRefresh}
            disabled={isRefreshing}
            className="gap-2"
          >
            <RefreshCw className={`h-4 w-4 ${isRefreshing ? 'animate-spin' : ''}`} />
            {isRefreshing ? 'Refreshing...' : 'Refresh'}
          </Button>
        </div>
      </div>

      {/* Main content */}
      <div className="grid gap-6 lg:grid-cols-2">
        {/* Shift detail card */}
        <ShiftDetailCard
          employeeName={employeeName}
          employeeId={employeeIdDisplay}
          shift={currentShift}
          isLoading={isLoading}
        />

        {/* GPS trail map with view toggle */}
        <div className="space-y-2">
          {/* Map view toggle */}
          <div className="flex items-center justify-end gap-1">
            <div className="flex items-center rounded-lg border bg-white p-1">
              <Button
                variant={mapViewMode === 'basic' ? 'secondary' : 'ghost'}
                size="sm"
                onClick={() => setMapViewMode('basic')}
                className="h-7 px-2 text-xs gap-1"
              >
                <Map className="h-3 w-3" />
                Basic
              </Button>
              <Button
                variant={mapViewMode === 'segmented' ? 'secondary' : 'ghost'}
                size="sm"
                onClick={() => setMapViewMode('segmented')}
                className="h-7 px-2 text-xs gap-1"
              >
                <Navigation className="h-3 w-3" />
                Segmented
              </Button>
            </div>
          </div>

          {/* Map display */}
          {mapViewMode === 'basic' ? (
            <GpsTrailMap
              trail={localTrail}
              isLoading={trailLoading && localTrail.length === 0}
              employeeName={employeeName}
            />
          ) : (
            <SegmentedTrailMap
              trail={localTrail}
              segments={segments}
              isLoading={trailLoading && localTrail.length === 0}
              selectedSegment={selectedSegment}
              onSegmentClick={handleSegmentClick}
              mode="realtime"
            />
          )}
        </div>
      </div>

      {/* Timeline visualization */}
      {currentShift && (
        <div className="grid gap-6 lg:grid-cols-3">
          <div className="lg:col-span-2">
            <TimelineBar
              segments={segments}
              totalDuration={shiftDuration}
              isLoading={timelineLoading}
              showLegend={true}
              showTimeMarkers={true}
              onSegmentClick={handleSegmentClick}
              selectedSegment={selectedSegment}
            />
          </div>
          <TimelineSummaryCard
            summary={timelineSummary}
            isLoading={timelineLoading}
          />
        </div>
      )}

      {/* Last updated indicator */}
      {lastUpdated && (
        <p className="text-xs text-slate-400 text-center">
          Last updated: {lastUpdated.toLocaleTimeString()}
        </p>
      )}
    </div>
  );
}

interface ConnectionIndicatorProps {
  status: ConnectionStatus;
}

function ConnectionIndicator({ status }: ConnectionIndicatorProps) {
  const config: Record<ConnectionStatus, { icon: typeof Wifi; color: string; text: string }> = {
    connected: { icon: Wifi, color: 'text-green-600', text: 'Live' },
    connecting: { icon: Wifi, color: 'text-yellow-600', text: 'Connecting...' },
    disconnected: { icon: WifiOff, color: 'text-slate-400', text: 'Offline' },
    error: { icon: WifiOff, color: 'text-red-600', text: 'Error' },
  };

  const { icon: Icon, color, text } = config[status];

  return (
    <div className={`flex items-center gap-1.5 text-sm ${color}`}>
      <Icon className="h-4 w-4" />
      <span>{text}</span>
    </div>
  );
}

function MapSkeleton() {
  return (
    <div className="rounded-lg border border-slate-200 bg-white">
      <div className="p-4 border-b border-slate-100">
        <Skeleton className="h-5 w-24" />
      </div>
      <Skeleton className="h-[400px] w-full" />
    </div>
  );
}
