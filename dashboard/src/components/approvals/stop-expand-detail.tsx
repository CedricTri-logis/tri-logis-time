'use client';

import { AlertTriangle } from 'lucide-react';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';
import { formatDurationMinutes } from '@/lib/utils/activity-display';
import type { ApprovalActivity } from '@/types/mileage';

export function StopExpandDetail({ activity }: { activity: ApprovalActivity }) {
  const cluster: StationaryCluster = {
    id: activity.activity_id,
    shift_id: activity.shift_id,
    employee_id: '',
    employee_name: '',
    centroid_latitude: activity.latitude ?? 0,
    centroid_longitude: activity.longitude ?? 0,
    centroid_accuracy: null,
    started_at: activity.started_at,
    ended_at: activity.ended_at,
    duration_seconds: activity.duration_minutes * 60,
    gps_point_count: 0,
    matched_location_id: activity.matched_location_id,
    matched_location_name: activity.location_name,
    created_at: activity.started_at,
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-muted/30 rounded-lg">
      <div className="lg:col-span-2">
        <StationaryClustersMap
          clusters={[cluster]}
          height={300}
          selectedClusterId={activity.activity_id}
        />
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        {(activity.gps_gap_seconds ?? 0) > 0 && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>
              Signal GPS perdu pendant {Math.round((activity.gps_gap_seconds ?? 0) / 60)} min
              ({activity.gps_gap_count ?? 0} interruption{(activity.gps_gap_count ?? 0) > 1 ? 's' : ''})
            </span>
          </div>
        )}
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Emplacement</span>
          <span className={`font-medium ${activity.location_name ? 'text-green-600' : 'text-amber-600'}`}>
            {activity.location_name || 'Non associé'}
          </span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Durée</span>
          <span className="font-medium">{formatDurationMinutes(activity.duration_minutes)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Coordonnées</span>
          <span className="font-mono text-xs">
            {activity.latitude?.toFixed(6)}, {activity.longitude?.toFixed(6)}
          </span>
        </div>
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Classification auto</span>
          <span className="text-xs">{activity.auto_reason}</span>
          {activity.override_status && (
            <span className="text-xs text-blue-600 ml-1">(modifié manuellement)</span>
          )}
        </div>
      </div>
    </div>
  );
}
