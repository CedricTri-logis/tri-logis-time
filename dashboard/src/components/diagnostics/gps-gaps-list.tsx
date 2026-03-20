import { cn } from '@/lib/utils';
import { format } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { GpsGap } from '@/types/gps-diagnostics';

interface GpsGapsListProps {
  gaps: GpsGap[];
  isLoading: boolean;
}

export function GpsGapsList({ gaps, isLoading }: GpsGapsListProps) {
  if (isLoading) {
    return <div className="space-y-2">{[...Array(3)].map((_, i) => (
      <div key={i} className="h-14 bg-slate-100 rounded-lg animate-pulse" />
    ))}</div>;
  }

  if (gaps.length === 0) {
    return <p className="text-sm text-slate-500 py-2">Aucun trou GPS détecté</p>;
  }

  return (
    <div className="space-y-2">
      {gaps.map((gap, idx) => (
        <div
          key={`${gap.shiftId}-${idx}`}
          className={cn(
            'rounded-lg border p-3',
            gap.gapMinutes > 30 ? 'bg-red-50 border-red-200' :
            gap.gapMinutes > 15 ? 'bg-amber-50 border-amber-200' :
            'bg-slate-50 border-slate-200'
          )}
        >
          <div className="flex justify-between items-center">
            <span className={cn(
              'font-bold text-sm',
              gap.gapMinutes > 30 ? 'text-red-600' : 'text-amber-600'
            )}>
              {gap.gapMinutes.toFixed(1)} min
            </span>
            <span className="text-xs text-slate-500">
              {format(gap.gapStart, 'd MMM', { locale: fr })}
            </span>
          </div>
          <div className="text-xs text-slate-500 mt-1">
            {format(gap.gapStart, 'HH:mm:ss')} → {format(gap.gapEnd, 'HH:mm:ss')}
          </div>
        </div>
      ))}
    </div>
  );
}
