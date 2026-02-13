'use client';

import { use, useMemo } from 'react';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { format } from 'date-fns';
import { ArrowLeft } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { useHistoricalTrail } from '@/lib/hooks/use-historical-gps';
import { usePlaybackAnimation } from '@/lib/hooks/use-playback-animation';

// Dynamically import the GPS trail map to avoid SSR issues with Leaflet
const GpsTrailMap = dynamic(
  () => import('@/components/monitoring/gps-trail-map').then((mod) => mod.GpsTrailMap),
  {
    ssr: false,
    loading: () => <Skeleton className="h-[400px] w-full rounded-lg" />,
  }
);
import { TrailInfoPanel } from '@/components/history/trail-info-panel';
import { EmptyGpsState } from '@/components/history/empty-gps-state';
import { GpsPlaybackControls } from '@/components/history/gps-playback-controls';
import { PlaybackTimeline } from '@/components/history/playback-timeline';
import { ExportDialog } from '@/components/history/export-dialog';
import { GpsTrailTable } from '@/components/history/gps-trail-table';
import { MapErrorBoundary } from '@/components/history/map-error-boundary';
import { calculateTotalDistance } from '@/lib/utils/distance';
import type { GpsTrailPoint } from '@/types/monitoring';
import type { GpsExportMetadata } from '@/types/history';

interface ShiftDetailPageProps {
  params: Promise<{
    shiftId: string;
  }>;
}

export default function ShiftDetailPage({ params }: ShiftDetailPageProps) {
  const { shiftId } = use(params);

  const { trail, isLoading, error } = useHistoricalTrail(shiftId);

  // Playback animation hook
  const {
    state: playbackState,
    currentPoint,
    progress,
    hasLargeGap,
    play,
    pause,
    seek,
    setSpeed,
    reset,
  } = usePlaybackAnimation(trail);

  // Convert HistoricalGpsPoint to GpsTrailPoint for map compatibility
  const mapTrail: GpsTrailPoint[] = useMemo(() => {
    return trail.map((p) => ({
      id: p.id,
      latitude: p.latitude,
      longitude: p.longitude,
      accuracy: p.accuracy ?? 0,
      capturedAt: p.capturedAt,
    }));
  }, [trail]);

  // Convert current animated point for map
  const animatedMapPoint: GpsTrailPoint | null = useMemo(() => {
    if (!currentPoint) return null;
    return {
      id: currentPoint.id,
      latitude: currentPoint.latitude,
      longitude: currentPoint.longitude,
      accuracy: currentPoint.accuracy ?? 0,
      capturedAt: currentPoint.capturedAt,
    };
  }, [currentPoint]);

  // Build export metadata
  const exportMetadata: GpsExportMetadata = useMemo(() => {
    const totalDistance = calculateTotalDistance(trail);
    const firstDate = trail[0]?.capturedAt;
    const lastDate = trail[trail.length - 1]?.capturedAt;

    return {
      employeeName: 'Employee', // Would need shift details to populate
      employeeId: shiftId,
      dateRange: firstDate && lastDate
        ? `${format(firstDate, 'yyyy-MM-dd')} to ${format(lastDate, 'yyyy-MM-dd')}`
        : 'Unknown',
      totalDistanceKm: totalDistance,
      totalPoints: trail.length,
      generatedAt: new Date().toISOString(),
    };
  }, [trail, shiftId]);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Link href="/dashboard/history">
            <Button variant="ghost" size="icon">
              <ArrowLeft className="h-4 w-4" />
            </Button>
          </Link>
          <div>
            <h1 className="text-2xl font-bold text-slate-900">Shift GPS Trail</h1>
            <p className="text-sm text-slate-500 mt-1">
              View and replay GPS movement trail for this shift
            </p>
          </div>
        </div>

        {/* Export button */}
        {trail.length > 0 && (
          <ExportDialog
            trail={trail}
            metadata={exportMetadata}
            buttonLabel="Export"
          />
        )}
      </div>

      {/* Error state */}
      {error && (
        <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
          {error}
        </div>
      )}

      {/* Empty GPS state */}
      {!isLoading && !error && trail.length === 0 && <EmptyGpsState />}

      {/* Trail info panel */}
      {(isLoading || trail.length > 0) && (
        <TrailInfoPanel
          trail={trail}
          shiftDate={trail[0]?.capturedAt}
          isLoading={isLoading}
        />
      )}

      {/* GPS Trail Map with animated marker - wrapped in error boundary */}
      {(isLoading || trail.length > 0) && (
        <MapErrorBoundary fallback={<GpsTrailTable trail={trail} />}>
          <GpsTrailMap
            trail={mapTrail}
            isLoading={isLoading}
            mode="historical"
            animatedPoint={animatedMapPoint}
            isPlaybackActive={playbackState.isPlaying || playbackState.currentIndex > 0}
          />
        </MapErrorBoundary>
      )}

      {/* Playback controls */}
      {trail.length > 1 && (
        <>
          <GpsPlaybackControls
            isPlaying={playbackState.isPlaying}
            currentSpeed={playbackState.speedMultiplier}
            onPlay={play}
            onPause={pause}
            onReset={reset}
            onSpeedChange={setSpeed}
          />

          <PlaybackTimeline
            trail={trail}
            currentIndex={playbackState.currentIndex}
            progress={progress}
            hasLargeGap={hasLargeGap}
            onSeek={seek}
          />
        </>
      )}
    </div>
  );
}
