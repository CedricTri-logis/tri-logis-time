import { cn } from '@/lib/utils';
import { format } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { GpsEvent } from '@/types/gps-diagnostics';

interface GpsCorrelatedTimelineProps {
  events: GpsEvent[];
  isLoading: boolean;
}

const SEVERITY_DOT: Record<string, string> = {
  error: 'bg-red-500',
  critical: 'bg-red-700',
  warn: 'bg-amber-500',
  info: 'bg-blue-400',
};

export function GpsCorrelatedTimeline({ events, isLoading }: GpsCorrelatedTimelineProps) {
  if (isLoading) {
    return <div className="space-y-3">{[...Array(5)].map((_, i) => (
      <div key={i} className="h-12 bg-slate-100 rounded animate-pulse" />
    ))}</div>;
  }

  if (events.length === 0) {
    return <p className="text-sm text-slate-500 py-2">Aucun événement</p>;
  }

  return (
    <div className="border-l-2 border-slate-200 pl-4 space-y-4">
      {events.map((evt) => (
        <div key={evt.id} className="relative">
          <div className={cn(
            'absolute -left-[21px] top-1 w-2.5 h-2.5 rounded-full',
            SEVERITY_DOT[evt.severity] ?? 'bg-slate-300'
          )} />
          <div className="text-xs text-slate-400">
            {format(evt.createdAt, 'd MMM HH:mm:ss', { locale: fr })}
          </div>
          <div className="text-sm text-slate-900">{evt.message}</div>
          <div className="text-xs text-slate-400 mt-0.5">
            {evt.eventCategory} · {evt.severity}
            {evt.metadata && typeof evt.metadata === 'object' && 'battery_level' in evt.metadata
              ? ` · batterie: ${evt.metadata.battery_level}%`
              : ''
            }
          </div>
        </div>
      ))}
    </div>
  );
}
