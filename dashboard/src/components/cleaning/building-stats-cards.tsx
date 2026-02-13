'use client';

import type { BuildingStats } from '@/types/cleaning';
import { formatDuration } from '@/types/cleaning';

interface BuildingStatsCardsProps {
  stats: BuildingStats[];
  isLoading: boolean;
}

function getProgressColor(cleaned: number, total: number, inProgress: number): string {
  if (total === 0) return 'bg-slate-200';
  if (cleaned === total) return 'bg-green-500';
  if (inProgress > 0) return 'bg-yellow-500';
  if (cleaned > 0) return 'bg-blue-500';
  return 'bg-slate-300';
}

export function BuildingStatsCards({ stats, isLoading }: BuildingStatsCardsProps) {
  if (isLoading) {
    return (
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="animate-pulse rounded-lg border bg-white p-4">
            <div className="h-4 w-24 rounded bg-slate-200" />
            <div className="mt-3 h-8 w-16 rounded bg-slate-200" />
            <div className="mt-2 h-2 rounded-full bg-slate-200" />
          </div>
        ))}
      </div>
    );
  }

  if (stats.length === 0) return null;

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
      {stats.map((building) => {
        const progressPct = building.totalStudios > 0
          ? Math.round((building.cleanedToday / building.totalStudios) * 100)
          : 0;
        const barColor = getProgressColor(
          building.cleanedToday,
          building.totalStudios,
          building.inProgress
        );

        return (
          <div
            key={building.buildingId}
            className="rounded-lg border bg-white p-4 shadow-sm"
          >
            <h3 className="text-sm font-medium text-slate-600">
              {building.buildingName}
            </h3>
            <div className="mt-2 flex items-baseline gap-1">
              <span className="text-2xl font-bold text-slate-900">
                {building.cleanedToday}
              </span>
              <span className="text-sm text-slate-500">
                / {building.totalStudios}
              </span>
            </div>

            {/* Progress bar */}
            <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-slate-100">
              <div
                className={`h-full rounded-full transition-all ${barColor}`}
                style={{ width: `${progressPct}%` }}
              />
            </div>

            <div className="mt-2 flex items-center justify-between text-xs text-slate-500">
              <span>{progressPct}% done</span>
              {building.inProgress > 0 && (
                <span className="text-blue-600">{building.inProgress} in progress</span>
              )}
            </div>

            {building.avgDurationMinutes > 0 && (
              <div className="mt-1 text-xs text-slate-400">
                Avg: {formatDuration(building.avgDurationMinutes)}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
